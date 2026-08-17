#!/usr/bin/env python3
"""Validate G10 draft lock shape without treating it as release evidence."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

GIT_SHA = re.compile(r"^[0-9a-f]{40}$")


def given_g10_draft_lock_when_validated_then_require_known_sources(lock: dict) -> None:
    if lock.get("lockVersion") != 1 or lock.get("status") != "draft-not-release-evidence":
        raise ValueError("G10 lock must remain a draft")
    repositories = lock.get("repositories", {})
    required = {"gymProto", "identifier", "member", "plans", "checkin"}
    if set(repositories) != required:
        raise ValueError("G10 lock repository set is invalid")
    for name, repository in repositories.items():
        if not isinstance(repository, dict) or not repository.get("url", "").startswith("https://github.com/"):
            raise ValueError(f"{name} URL is invalid")
        if GIT_SHA.fullmatch(repository.get("sha", "")) is None:
            raise ValueError(f"{name} SHA is invalid")
    if lock.get("gymProto", {}).get("sourceSha") != repositories["gymProto"]["sha"]:
        raise ValueError("gymProto source SHA mismatch")
    if lock.get("dependencies") != {"javaProto": "7.0.2", "goProto": "v1.7.1"}:
        raise ValueError("G10 contract dependency mismatch")
    if lock.get("routes") != {"count": 33, "byOwner": {"identity": 12, "member": 7, "plans": 8, "checkin": 6}}:
        raise ValueError("G10 route count mismatch")
    if not isinstance(lock.get("requiredFinalization"), list) or not lock["requiredFinalization"]:
        raise ValueError("G10 lock finalization requirements are missing")


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: validate-g10-lock.py LOCK")
    path = Path(sys.argv[1])
    given_g10_draft_lock_when_validated_then_require_known_sources(json.loads(path.read_text()))
    print(f"G10 draft lock valid: {path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        print(f"G10 lock validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)

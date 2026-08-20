#!/usr/bin/env python3
"""Validate immutable G10 release-lock metadata before any fixture starts."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

GIT_SHA = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
DIGEST_IMAGE = re.compile(r"^[a-z0-9./_-]+(?:[:][a-z0-9._-]+)?@sha256:[0-9a-f]{64}$")
REPOSITORY_NAMES = {"gymProto", "identifier", "member", "plans", "checkin", "infrastructure"}
IMAGE_NAMES = {"identifier", "member", "plans", "checkin", "gateway", "postgres", "redis", "yugabyte", "localstack", "kafka", "schemaRegistry", "kong"}
CHECKSUM_NAMES = {"compose", "certGenerator", "gatewayGoMod", "gatewayGoSum", "migration"}
ROUTES = {"count": 33, "byOwner": {"identity": 12, "member": 7, "plans": 8, "checkin": 6}}


def _mapping(value: object, message: str) -> dict:
    if not isinstance(value, dict):
        raise ValueError(message)
    return value


def given_final_g10_lock_when_validated_then_require_immutable_inputs(lock: dict) -> None:
    if lock.get("lockVersion") != 2 or lock.get("status") != "final-technical-gates-pending":
        raise ValueError("G10 lock must be final technical-gates-pending")

    proto = _mapping(lock.get("gymProto"), "gymProto metadata is invalid")
    repositories = _mapping(lock.get("repositories"), "G10 repositories are invalid")
    if set(repositories) != REPOSITORY_NAMES:
        raise ValueError("G10 lock repository set is invalid")
    if proto.get("sourceSha") != repositories["gymProto"].get("sha"):
        raise ValueError("gymProto source SHA mismatch")
    if proto.get("sourceSha") == "e29a1327d004a2f19676227c1668365ffa45a293":
        raise ValueError("gymProto source SHA must be peeled commit")
    if proto.get("version") != "v7.0.2" or not proto.get("releaseUrl", "").startswith("https://github.com/"):
        raise ValueError("gymProto release metadata is invalid")

    for name, repository in repositories.items():
        repository = _mapping(repository, f"{name} repository is invalid")
        if not repository.get("url", "").startswith("https://github.com/"):
            raise ValueError(f"{name} URL is invalid")
        if GIT_SHA.fullmatch(repository.get("sha", "")) is None:
            raise ValueError(f"{name} SHA is invalid")

    if lock.get("dependencies") != {"javaProto": "7.0.2", "goProto": "v1.7.1"}:
        raise ValueError("G10 contract dependency mismatch")

    routes = _mapping(lock.get("routes"), "G10 routes are invalid")
    if {key: routes.get(key) for key in ROUTES} != ROUTES:
        raise ValueError("G10 route inventory mismatch")
    for name in ("manifestSha256", "templateSha256"):
        if SHA256.fullmatch(routes.get(name, "")) is None:
            raise ValueError(f"G10 route {name} is invalid")

    images = _mapping(lock.get("images"), "G10 images are invalid")
    if set(images) != IMAGE_NAMES:
        raise ValueError("G10 image set is invalid")
    for name, image in images.items():
        if not isinstance(image, str) or DIGEST_IMAGE.fullmatch(image) is None:
            raise ValueError(f"{name} image is not digest pinned")

    checksums = _mapping(lock.get("checksums"), "G10 checksums are invalid")
    if set(checksums) != CHECKSUM_NAMES:
        raise ValueError("G10 checksum set is invalid")
    for name, digest in checksums.items():
        if SHA256.fullmatch(digest) is None:
            raise ValueError(f"{name} checksum is invalid")

    runs = lock.get("protectedRuns")
    if not isinstance(runs, list) or not runs or any(not isinstance(url, str) or not url.startswith("https://github.com/") for url in runs):
        raise ValueError("protected G10 run URLs are invalid")
    finalization = lock.get("requiredFinalization")
    if not isinstance(finalization, list) or not finalization:
        raise ValueError("G10 finalization requirements are missing")


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: validate-g10-lock.py LOCK")
    path = Path(sys.argv[1])
    given_final_g10_lock_when_validated_then_require_immutable_inputs(json.loads(path.read_text()))
    print(f"G10 final lock metadata valid: {path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        print(f"G10 lock validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)

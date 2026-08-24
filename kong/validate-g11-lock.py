#!/usr/bin/env python3
"""Validate G11 image lock before runtime proof."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

GIT_SHA = re.compile(r"^[0-9a-f]{40}$")
DIGEST_IMAGE = re.compile(r"^[a-z0-9./_-]+(?::[a-z0-9._-]+)?@sha256:[0-9a-f]{64}$")
REPOSITORIES = {"gymProto", "identifier", "member", "plans", "checkin", "payment", "infrastructure"}
IMAGES = {"identifier", "member", "plans", "checkin", "payment", "gateway", "postgres", "redis", "yugabyte", "localstack", "kafka", "schemaRegistry", "kong", "buf", "schemaSeed"}


def given_g11_image_lock_when_validated_then_require_pinned_sources_and_images(lock: dict) -> None:
    if lock.get("lockVersion") != 2 or lock.get("status") != "image-lock-pending-gate":
        raise ValueError("G11 lock status is invalid")
    repositories = lock.get("repositories")
    if not isinstance(repositories, dict) or set(repositories) != REPOSITORIES:
        raise ValueError("G11 repository set is invalid")
    for name, repository in repositories.items():
        if not isinstance(repository, dict) or not str(repository.get("url", "")).startswith("https://github.com/"):
            raise ValueError(f"{name} repository is invalid")
        if set(repository) != {"url", "sha"} or GIT_SHA.fullmatch(str(repository.get("sha", ""))) is None:
            raise ValueError(f"{name} SHA is invalid")
    images = lock.get("images")
    if not isinstance(images, dict) or set(images) != IMAGES:
        raise ValueError("G11 image set is invalid")
    for name, image in images.items():
        if not isinstance(image, str) or DIGEST_IMAGE.fullmatch(image) is None:
            raise ValueError(f"{name} image is not digest pinned")
    webhook = lock.get("routes", {}).get("paymentWebhook")
    if webhook != {"method": "POST", "path": "/api/v1/payments/webhook/sepay", "jwt": False, "rawBodyPreserved": True}:
        raise ValueError("G11 webhook route lock is invalid")
    if not lock.get("requiredFinalization"):
        raise ValueError("G11 finalization is missing")


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: validate-g11-lock.py LOCK")
    path = Path(sys.argv[1])
    given_g11_image_lock_when_validated_then_require_pinned_sources_and_images(json.loads(path.read_text()))
    print(f"G11 image lock metadata valid: {path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, json.JSONDecodeError, TypeError, ValueError) as error:
        print(f"G11 lock validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)

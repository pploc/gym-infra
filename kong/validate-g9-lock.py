#!/usr/bin/env python3
"""Validate static shape of immutable G9 release lock."""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path


SHA256 = re.compile(r"^[0-9a-f]{64}$")
GIT_SHA = re.compile(r"^[0-9a-f]{40}$")


def require(value: bool, message: str) -> None:
    if not value:
        raise ValueError(message)


def given_g9_lock_when_validated_then_require_immutable_inputs(lock: dict) -> None:
    require(lock.get("lockVersion") == 2, "lockVersion must be 2")
    gym_proto = lock.get("gymProto", {})
    require(isinstance(gym_proto, dict), "gymProto is required")
    require(GIT_SHA.fullmatch(gym_proto.get("sourceSha", "")) is not None, "gymProto sourceSha is invalid")
    require(isinstance(gym_proto.get("version"), str) and gym_proto["version"].startswith("v"), "gymProto version is invalid")

    repositories = lock.get("repositories", {})
    required_repositories = {"gymProto", "identifier", "member", "plans"}
    require(set(repositories) == required_repositories, "repositories must lock gymProto, identifier, member, and plans")
    for name, repository in repositories.items():
        require(isinstance(repository.get("url"), str) and repository["url"].startswith("https://github.com/"), f"{name} URL is invalid")
        require(GIT_SHA.fullmatch(repository.get("sha", "")) is not None, f"{name} SHA is invalid")
    require(repositories["gymProto"]["sha"] == gym_proto["sourceSha"], "gymProto source SHA mismatch")

    artifacts = lock.get("artifacts", {})
    canonical_openapi = artifacts.get("canonicalOpenApi")
    require(isinstance(canonical_openapi, dict), "canonical OpenAPI artifact is required")
    require(isinstance(canonical_openapi.get("url"), str) and canonical_openapi["url"].startswith("https://github.com/"), "canonical OpenAPI URL is invalid")
    require(SHA256.fullmatch(canonical_openapi.get("sha256", "")) is not None, "canonical OpenAPI checksum is invalid")

    gateway = lock.get("gateway", {})
    require(GIT_SHA.fullmatch(gateway.get("sourceCommit", "")) is not None, "gateway source commit is invalid")
    require(isinstance(gateway.get("image"), str) and "@sha256:" in gateway["image"], "gateway image must be digest pinned")
    require(SHA256.fullmatch(gateway["image"].split("@sha256:")[-1]) is not None, "gateway image digest is invalid")
    for key in ("goModSha256", "goSumSha256", "fakePaymentGoModSha256", "fakePaymentGoSumSha256"):
        require(SHA256.fullmatch(gateway.get(key, "")) is not None, f"gateway {key} is invalid")

    dependencies = lock.get("dependencies", {})
    require(re.fullmatch(r"\d+\.\d+\.\d+", dependencies.get("javaProto", "")) is not None, "Java contract version is invalid")
    require(re.fullmatch(r"v\d+\.\d+\.\d+", dependencies.get("goProto", "")) is not None, "Go contract version is invalid")

    kong = lock.get("kong", {})
    require("@sha256:" in kong.get("image", ""), "Kong image must be digest pinned")
    require(SHA256.fullmatch(kong["image"].split("@sha256:")[-1]) is not None, "Kong digest is invalid")

    routes = lock.get("routes", {})
    require(routes.get("count") == 27, "route count must be 27")
    for key in ("manifestSha256", "templateSha256"):
        require(SHA256.fullmatch(routes.get(key, "")) is not None, f"route {key} is invalid")


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: validate-g9-lock.py LOCK")
    path = Path(sys.argv[1])
    lock = json.loads(path.read_text())
    given_g9_lock_when_validated_then_require_immutable_inputs(lock)
    print(f"G9 lock valid: {path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        print(f"G9 lock validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)

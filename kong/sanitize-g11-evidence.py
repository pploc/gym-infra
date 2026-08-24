#!/usr/bin/env python3
"""Validate and emit image-locked G11 evidence without sensitive values."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import yaml

SHA = re.compile(r"^[0-9a-f]{40}$")
DIGEST = re.compile(r"^[a-z0-9./_-]+(?::[a-z0-9._-]+)?@sha256:[0-9a-f]{64}$")
FORBIDDEN = re.compile(
    r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----|"
    r"(?:authorization|proxy-authorization|refresh[_ -]?token|aws_access_key_id|aws_secret_access_key|"
    r"kms[_ -]?(?:plaintext|ciphertext)|database[_ -]?password)\s*[:=]|"
    r"bearer\s+|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|"
    r"stack[ _-]*trace|org\.springframework|caused by:|"
    r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b|"
    r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}",
    re.IGNORECASE,
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def sanitize(raw: object, lock: dict) -> dict:
    source = raw if isinstance(raw, dict) else None
    require(source is not None, "G11 evidence must be a mapping")
    require(set(source) == {"schemaVersion", "mode", "gates", "checks"}, "G11 evidence keys are invalid")
    require(source["schemaVersion"] == 1, "G11 evidence schema version is invalid")
    require(source["mode"] == "image-lock-pending-gate", "G11 evidence mode is invalid")

    gates = source["gates"]
    require(isinstance(gates, dict) and gates.get("result") == "passed", "G11 gates did not pass")
    require(isinstance(gates.get("exitCodes"), dict), "G11 exit codes are invalid")

    checks = source["checks"]
    require(isinstance(checks, list) and checks, "G11 checks are missing")
    for check in checks:
        require(isinstance(check, dict) and set(check) == {"name", "result", "exitCode"}, "G11 check is invalid")
        require(isinstance(check["name"], str) and check["name"], "G11 check name is invalid")
        require(check["result"] == "passed" and check["exitCode"] == 0, "G11 check did not pass")

    source_shas = {name: repository.get("sha") for name, repository in lock["repositories"].items()}
    for sha in source_shas.values():
        require(isinstance(sha, str) and SHA.fullmatch(sha), "G11 source SHA is invalid")
    for image in lock["images"].values():
        require(isinstance(image, str) and DIGEST.fullmatch(image), "G11 image is invalid")

    evidence = {
        "schemaVersion": 1,
        "mode": source["mode"],
        "lock": {"sourceShas": source_shas, "imageDigests": lock["images"]},
        "gates": gates,
        "checks": checks,
    }
    rendered = yaml.safe_dump(evidence, allow_unicode=False, sort_keys=True)
    require(FORBIDDEN.search(rendered) is None, "G11 evidence contains sensitive data")
    return evidence


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit("usage: sanitize-g11-evidence.py LOCK RAW_EVIDENCE OUTPUT")
    lock_path, raw_path, output_path = map(Path, sys.argv[1:])
    lock = json.loads(lock_path.read_text())
    output_path.write_text(yaml.safe_dump(sanitize(yaml.safe_load(raw_path.read_text()), lock), allow_unicode=False, sort_keys=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError, yaml.YAMLError) as error:
        print(f"G11 evidence sanitization failed: {error}", file=sys.stderr)
        raise SystemExit(1)

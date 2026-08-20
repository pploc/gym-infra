#!/usr/bin/env python3
"""Validate and emit schema-controlled G10 evidence only."""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

SHA256 = re.compile(r"^[0-9a-f]{64}$")
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


def mapping(value: object, message: str) -> dict:
    require(isinstance(value, dict), message)
    return value


def sanitize(raw: object) -> dict:
    source = mapping(raw, "G10 evidence must be a mapping")
    require(set(source) == {"schemaVersion", "lock", "gates", "checks"}, "G10 evidence keys are invalid")
    require(source["schemaVersion"] == 1, "G10 evidence schema version is invalid")

    lock = mapping(source["lock"], "G10 lock evidence is invalid")
    require(set(lock) == {"sourceShas", "imageDigests", "checksums"}, "G10 lock evidence keys are invalid")
    for value in lock["sourceShas"].values():
        require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value), "source SHA is invalid")
    for value in lock["imageDigests"].values():
        require(isinstance(value, str) and "@sha256:" in value and SHA256.fullmatch(value.rsplit("@sha256:", 1)[1]), "image digest is invalid")
    for value in lock["checksums"].values():
        require(isinstance(value, str) and SHA256.fullmatch(value), "checksum is invalid")

    gates = mapping(source["gates"], "G10 gates are invalid")
    require(gates.get("result") == "passed", "G10 gates did not pass")
    require(isinstance(gates.get("exitCodes"), dict), "G10 exit codes are invalid")

    checks = source["checks"]
    require(isinstance(checks, list) and checks, "G10 checks are missing")
    safe_checks = []
    for check in checks:
        item = mapping(check, "G10 check is invalid")
        require(set(item) == {"name", "result", "exitCode"}, "G10 check fields are invalid")
        require(isinstance(item["name"], str) and item["name"], "G10 check name is invalid")
        require(item["result"] == "passed" and item["exitCode"] == 0, "G10 check did not pass")
        safe_checks.append(item)

    evidence = {"schemaVersion": 1, "lock": lock, "gates": gates, "checks": safe_checks}
    rendered = yaml.safe_dump(evidence, allow_unicode=False, sort_keys=True)
    require(FORBIDDEN.search(rendered) is None, "G10 evidence contains sensitive data")
    return evidence


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: sanitize-g10-evidence.py RAW_EVIDENCE OUTPUT")
    source, output = map(Path, sys.argv[1:])
    output.write_text(yaml.safe_dump(sanitize(yaml.safe_load(source.read_text())), allow_unicode=False, sort_keys=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, yaml.YAMLError) as error:
        print(f"G10 evidence sanitization failed: {error}", file=sys.stderr)
        raise SystemExit(1)

#!/usr/bin/env python3
"""Create schema-controlled G9 evidence without request values or response bodies."""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml


CASE_NAMES = (
    "route_not_found",
    "jwt_missing",
    "jwt_invalid_role",
    "identifier_validation",
    "plans_transcoding_invalid_json",
    "plans_validation",
    "member_transcoding_invalid_json",
    "member_transcoding_invalid_query",
    "member_forbidden",
    "plans_not_found",
    "identifier_conflict",
    "service_500",
    "service_503",
)
SHA256 = re.compile(r"^[0-9a-f]{64}$")
FORBIDDEN = re.compile(
    r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----|"
    r"authorization\s*:|bearer\s+|"
    r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|"
    r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|"
    r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b|"
    r"(?:stack[ _-]*trace|org\.springframework|caused by:)",
    re.IGNORECASE,
)
SAFE_ERRORS = {
    "service_500": (500, '{"code":13, "message":"Internal server error", "details":[]}'),
    "service_503": (503, '{"code":14, "message":"Upstream service unavailable", "details":[]}'),
}


def require(value: bool, message: str) -> None:
    if not value:
        raise ValueError(message)


def require_mapping(value: object, message: str) -> dict:
    require(isinstance(value, dict), message)
    return value


def sanitize_case(case: object) -> dict:
    source = require_mapping(case, "measurement case must be a mapping")
    name = source.get("case")
    require(name in CASE_NAMES, f"unexpected evidence case: {name}")
    expected = source.get("expected_http_status")
    actual = source.get("http_status")
    require(isinstance(expected, int) and 100 <= expected <= 599, f"{name} expected status is invalid")
    require(isinstance(actual, int) and 100 <= actual <= 599, f"{name} actual status is invalid")

    body = require_mapping(source.get("body"), f"{name} body is invalid")
    digest = body.get("sha256")
    require(isinstance(digest, str) and SHA256.fullmatch(digest) is not None, f"{name} body checksum is invalid")

    cors = require_mapping(source.get("cors"), f"{name} CORS data is invalid")
    for key in ("status_and_body_browser_readable", "x_error_code_browser_readable"):
        require(isinstance(cors.get(key), bool), f"{name} {key} is invalid")
    require(isinstance(source.get("contains_internal_exception_text"), bool), f"{name} exception check is invalid")

    if name in SAFE_ERRORS:
        safe_status, safe_body = SAFE_ERRORS[name]
        require(actual == safe_status, f"{name} status is not browser-safe")
        require(body.get("value") == safe_body, f"{name} body is not browser-safe")

    return {
        "name": name,
        "expectedHttpStatus": expected,
        "httpStatus": actual,
        "contentType": source.get("content_type"),
        "bodySha256": digest,
        "statusAndBodyBrowserReadable": cors["status_and_body_browser_readable"],
        "errorCodeBrowserReadable": cors["x_error_code_browser_readable"],
        "containsInternalExceptionText": source["contains_internal_exception_text"],
    }


def given_raw_g9_measurement_when_sanitized_then_emit_safe_summary(raw: object) -> dict:
    source = require_mapping(raw, "raw G9 evidence must be a mapping")
    measurement = require_mapping(source.get("measurement"), "measurement is required")
    cases = measurement.get("cases")
    require(isinstance(cases, list), "measurement cases are required")
    sanitized_cases = [sanitize_case(case) for case in cases]
    require(tuple(item["name"] for item in sanitized_cases) == CASE_NAMES, "measurement case set is invalid")
    require(all(item["expectedHttpStatus"] == item["httpStatus"] for item in sanitized_cases), "measurement status mismatch")
    require(all(not item["containsInternalExceptionText"] for item in sanitized_cases), "internal exception text observed")

    gate = require_mapping(source.get("gate"), "measurement gate is required")
    require(gate.get("result") == "passed", "measurement gate did not pass")
    kong = require_mapping(source.get("kong"), "Kong metadata is required")
    require(isinstance(kong.get("version"), (str, int, float)), "Kong version is invalid")

    summary = {
        "schemaVersion": 1,
        "topology": "kong-generated-go-grpc-gateway",
        "measurement": {
            "kongVersion": str(kong["version"]),
            "cases": sanitized_cases,
        },
        "gates": {
            "compatibility": "passed",
            "releaseReady": False,
        },
    }
    given_sanitized_g9_evidence_when_validated_then_reject_sensitive_data(summary)
    return summary


def given_sanitized_g9_evidence_when_validated_then_reject_sensitive_data(evidence: object) -> None:
    source = require_mapping(evidence, "sanitized G9 evidence must be a mapping")
    require(set(source) == {"schemaVersion", "topology", "measurement", "gates"}, "sanitized evidence keys are invalid")
    require(source.get("schemaVersion") == 1, "sanitized evidence schema version is invalid")
    require(source.get("topology") == "kong-generated-go-grpc-gateway", "sanitized evidence topology is invalid")

    measurement = require_mapping(source.get("measurement"), "sanitized measurement is invalid")
    require(set(measurement) == {"kongVersion", "cases"}, "sanitized measurement keys are invalid")
    cases = measurement.get("cases")
    require(isinstance(cases, list) and len(cases) == len(CASE_NAMES), "sanitized case count is invalid")
    require(tuple(case.get("name") for case in cases if isinstance(case, dict)) == CASE_NAMES, "sanitized case order is invalid")
    for case in cases:
        require_mapping(case, "sanitized case is invalid")
        require(
            set(case) == {
                "name", "expectedHttpStatus", "httpStatus", "contentType", "bodySha256",
                "statusAndBodyBrowserReadable", "errorCodeBrowserReadable", "containsInternalExceptionText",
            },
            "sanitized case keys are invalid",
        )
        require(SHA256.fullmatch(case["bodySha256"]) is not None, "sanitized body checksum is invalid")
        require(case["expectedHttpStatus"] == case["httpStatus"], "sanitized status mismatch")
        require(case["containsInternalExceptionText"] is False, "sanitized evidence includes internal exception text")

    gates = require_mapping(source.get("gates"), "sanitized gates are invalid")
    require(gates == {"compatibility": "passed", "releaseReady": False}, "sanitized gates are invalid")
    rendered = yaml.safe_dump(source, allow_unicode=False, sort_keys=True)
    require(FORBIDDEN.search(rendered) is None, "sanitized evidence contains sensitive data")


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: sanitize-g9-evidence.py RAW_EVIDENCE OUTPUT")
    raw_path, output_path = map(Path, sys.argv[1:])
    raw = yaml.safe_load(raw_path.read_text())
    summary = given_raw_g9_measurement_when_sanitized_then_emit_safe_summary(raw)
    output_path.write_text(yaml.safe_dump(summary, allow_unicode=False, sort_keys=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, yaml.YAMLError) as error:
        print(f"G9 evidence sanitization failed: {error}", file=sys.stderr)
        raise SystemExit(1)

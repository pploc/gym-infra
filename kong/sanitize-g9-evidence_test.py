#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("sanitize_g9_evidence", ROOT / "sanitize-g9-evidence.py")
SANITIZE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(SANITIZE)


def given_raw_measurement() -> dict:
    cases = []
    for name in SANITIZE.CASE_NAMES:
        status = 500 if name == "service_500" else 503 if name == "service_503" else 400
        body = '{"code":13, "message":"Internal server error", "details":[]}' if name == "service_500" else (
            '{"code":14, "message":"Upstream service unavailable", "details":[]}' if name == "service_503" else "{}"
        )
        cases.append(
            {
                "case": name,
                "expected_http_status": status,
                "http_status": status,
                "content_type": "application/json",
                "body": {"value": body, "sha256": "a" * 64},
                "cors": {
                    "status_and_body_browser_readable": True,
                    "x_error_code_browser_readable": name == "service_500",
                },
                "contains_internal_exception_text": False,
            }
        )
    return {"kong": {"version": "3.8"}, "measurement": {"cases": cases}, "gate": {"result": "passed"}}


class SanitizeG9EvidenceTest(unittest.TestCase):
    def test_given_safe_measurement_when_sanitized_then_emit_summary_without_bodies(self):
        # given
        raw = given_raw_measurement()

        # when
        summary = SANITIZE.given_raw_g9_measurement_when_sanitized_then_emit_safe_summary(raw)

        # then
        self.assertEqual(summary["topology"], "kong-generated-go-grpc-gateway")
        self.assertNotIn("body", summary["measurement"]["cases"][0])
        self.assertEqual(summary["measurement"]["cases"][-1]["name"], "service_503")

    def test_given_jwt_in_sanitized_evidence_when_validated_then_reject(self):
        # given
        summary = SANITIZE.given_raw_g9_measurement_when_sanitized_then_emit_safe_summary(given_raw_measurement())
        summary["measurement"]["kongVersion"] = "eyJhbGciOiJIUzI1NiJ9.payload.signature"

        # when / then
        with self.assertRaisesRegex(ValueError, "sensitive"):
            SANITIZE.given_sanitized_g9_evidence_when_validated_then_reject_sensitive_data(summary)


if __name__ == "__main__":
    unittest.main()

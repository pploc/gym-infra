#!/usr/bin/env python3
import importlib.util
import unittest
from copy import deepcopy
from pathlib import Path

ROOT = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("sanitize_g10_evidence", ROOT / "sanitize-g10-evidence.py")
SANITIZE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(SANITIZE)


class SanitizeG10EvidenceTest(unittest.TestCase):
    def setUp(self):
        self.evidence = {
            "schemaVersion": 1,
            "lock": {
                "sourceShas": {"checkin": "e26e2089338808f53706e91ee575607646bf631f"},
                "imageDigests": {"checkin": "ghcr.io/pploc/ms-gym-checkin@sha256:" + "a" * 64},
                "checksums": {"compose": "b" * 64},
            },
            "gates": {"result": "passed", "exitCodes": {"business": 0}},
            "checks": [{"name": "business", "result": "passed", "exitCode": 0}],
        }

    def test_given_safe_evidence_when_sanitized_then_accept(self):
        self.assertEqual(SANITIZE.sanitize(self.evidence)["schemaVersion"], 1)

    def test_given_bearer_token_when_sanitized_then_reject(self):
        evidence = deepcopy(self.evidence)
        evidence["checks"][0]["name"] = "bearer token"
        with self.assertRaisesRegex(ValueError, "sensitive"):
            SANITIZE.sanitize(evidence)

    def test_given_private_key_when_sanitized_then_reject(self):
        evidence = deepcopy(self.evidence)
        evidence["checks"][0]["name"] = "-----BEGIN PRIVATE KEY-----"
        with self.assertRaisesRegex(ValueError, "sensitive"):
            SANITIZE.sanitize(evidence)

    def test_given_nonzero_check_when_sanitized_then_reject(self):
        evidence = deepcopy(self.evidence)
        evidence["checks"][0]["exitCode"] = 1
        with self.assertRaisesRegex(ValueError, "did not pass"):
            SANITIZE.sanitize(evidence)


if __name__ == "__main__":
    unittest.main()

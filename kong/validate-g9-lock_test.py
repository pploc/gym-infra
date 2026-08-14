#!/usr/bin/env python3
import importlib.util
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("validate_g9_lock", ROOT / "validate-g9-lock.py")
VALIDATE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(VALIDATE)


class ValidateG9LockTest(unittest.TestCase):
    def test_given_committed_lock_when_validated_then_accept(self):
        # given
        lock = json.loads((ROOT / "g9-release-lock.json").read_text())

        # when / then
        VALIDATE.given_g9_lock_when_validated_then_require_immutable_inputs(lock)

    def test_given_mutable_kong_image_when_validated_then_reject(self):
        # given
        lock = json.loads((ROOT / "g9-release-lock.json").read_text())
        lock["kong"]["image"] = "kong:3.8-ubuntu"

        # when / then
        with self.assertRaisesRegex(ValueError, "digest pinned"):
            VALIDATE.given_g9_lock_when_validated_then_require_immutable_inputs(lock)

    def test_given_malformed_canonical_openapi_when_validated_then_reject(self):
        # given
        lock = json.loads((ROOT / "g9-release-lock.json").read_text())
        lock["artifacts"]["canonicalOpenApi"]["sha256"] = "not-a-checksum"

        # when / then
        with self.assertRaisesRegex(ValueError, "canonical OpenAPI checksum"):
            VALIDATE.given_g9_lock_when_validated_then_require_immutable_inputs(lock)

    def test_given_mutable_gateway_image_when_validated_then_reject(self):
        # given
        lock = json.loads((ROOT / "g9-release-lock.json").read_text())
        lock["gateway"]["image"] = "ghcr.io/pploc/ms-gym-api-gateway:develop"

        # when / then
        with self.assertRaisesRegex(ValueError, "gateway image must be digest pinned"):
            VALIDATE.given_g9_lock_when_validated_then_require_immutable_inputs(lock)


if __name__ == "__main__":
    unittest.main()

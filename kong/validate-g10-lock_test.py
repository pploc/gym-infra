#!/usr/bin/env python3
import importlib.util
import json
import unittest
from copy import deepcopy
from pathlib import Path

ROOT = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("validate_g10_lock", ROOT / "validate-g10-lock.py")
VALIDATE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(VALIDATE)


class ValidateG10LockTest(unittest.TestCase):
    def setUp(self):
        self.lock = json.loads((ROOT / "g10-release-lock.json").read_text())

    def test_given_draft_lock_when_validated_then_accept(self):
        # given / when / then
        VALIDATE.given_g10_draft_lock_when_validated_then_require_known_sources(self.lock)

    def test_given_missing_checkin_source_when_validated_then_reject(self):
        # given
        lock = deepcopy(self.lock)
        del lock["repositories"]["checkin"]

        # when / then
        with self.assertRaisesRegex(ValueError, "repository set"):
            VALIDATE.given_g10_draft_lock_when_validated_then_require_known_sources(lock)

    def test_given_finalized_status_when_validated_then_reject(self):
        # given
        lock = deepcopy(self.lock)
        lock["status"] = "final"

        # when / then
        with self.assertRaisesRegex(ValueError, "draft"):
            VALIDATE.given_g10_draft_lock_when_validated_then_require_known_sources(lock)


if __name__ == "__main__":
    unittest.main()

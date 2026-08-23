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

    def test_given_final_lock_when_validated_then_accept(self):
        # given / when / then
        VALIDATE.given_final_g10_lock_when_validated_then_require_immutable_inputs(self.lock)

    def test_given_mismatched_proto_sha_when_validated_then_reject(self):
        lock = deepcopy(self.lock)
        lock["gymProto"]["sourceSha"] = "e29a1327d004a2f19676227c1668365ffa45a293"
        with self.assertRaisesRegex(ValueError, "source SHA"):
            VALIDATE.given_final_g10_lock_when_validated_then_require_immutable_inputs(lock)

    def test_given_annotated_proto_sha_with_matching_record_when_validated_then_reject(self):
        lock = deepcopy(self.lock)
        lock["gymProto"]["sourceSha"] = "e29a1327d004a2f19676227c1668365ffa45a293"
        lock["repositories"]["gymProto"]["sha"] = lock["gymProto"]["sourceSha"]
        with self.assertRaisesRegex(ValueError, "source SHA"):
            VALIDATE.given_final_g10_lock_when_validated_then_require_immutable_inputs(lock)

    def test_given_tagged_image_when_validated_then_reject(self):
        lock = deepcopy(self.lock)
        lock["images"]["checkin"] = "ghcr.io/pploc/ms-gym-checkin:develop"
        with self.assertRaisesRegex(ValueError, "digest pinned"):
            VALIDATE.given_final_g10_lock_when_validated_then_require_immutable_inputs(lock)

    def test_given_missing_repository_when_validated_then_reject(self):
        lock = deepcopy(self.lock)
        del lock["repositories"]["infrastructure"]
        with self.assertRaisesRegex(ValueError, "repository set"):
            VALIDATE.given_final_g10_lock_when_validated_then_require_immutable_inputs(lock)

    def test_given_pending_lock_without_finalization_when_validated_then_reject(self):
        lock = deepcopy(self.lock)
        lock["status"] = "final-technical-gates-pending"
        lock["requiredFinalization"] = []
        with self.assertRaisesRegex(ValueError, "finalization requirements are missing"):
            VALIDATE.given_final_g10_lock_when_validated_then_require_immutable_inputs(lock)

    def test_given_complete_lock_with_finalization_when_validated_then_reject(self):
        lock = deepcopy(self.lock)
        lock["status"] = "complete"
        lock["requiredFinalization"] = ["owner acceptance"]
        with self.assertRaisesRegex(ValueError, "clear finalization"):
            VALIDATE.given_final_g10_lock_when_validated_then_require_immutable_inputs(lock)


if __name__ == "__main__":
    unittest.main()

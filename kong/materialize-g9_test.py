#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "materialize_g9", Path(__file__).with_name("materialize-g9.py")
)
MATERIALIZE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MATERIALIZE)


class MaterializeG9Test(unittest.TestCase):
    def test_given_lock_without_every_repository_when_checked_then_reject(self):
        # given
        lock = {"repositories": {"gymProto": {}}}

        # when / then
        with self.assertRaisesRegex(ValueError, "repositories must be"):
            MATERIALIZE.validate_repositories(lock)

    def test_given_non_github_repository_when_checked_then_reject(self):
        # given
        lock = {
            "repositories": {
                name: {"url": "file:///tmp/source", "sha": "a" * 40}
                for name in MATERIALIZE.ENVIRONMENT_NAMES
            }
        }

        # when / then
        with self.assertRaisesRegex(ValueError, "URL is invalid"):
            MATERIALIZE.validate_repositories(lock)


if __name__ == "__main__":    unittest.main()

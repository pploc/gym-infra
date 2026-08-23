#!/usr/bin/env python3
import importlib.util
import os
import unittest
from pathlib import Path
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "materialize_g10", Path(__file__).with_name("materialize-g10.py")
)
MATERIALIZE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MATERIALIZE)


class MaterializeG10Test(unittest.TestCase):
    def test_given_windows_autocrlf_when_materializing_then_checkout_stays_byte_stable(self):
        # given / when
        with patch.dict(os.environ, {"GITHUB_TOKEN": "token"}, clear=True):
            environment = MATERIALIZE.git_environment()

        # then
        self.assertEqual("2", environment["GIT_CONFIG_COUNT"])
        self.assertEqual("core.autocrlf", environment["GIT_CONFIG_KEY_0"])
        self.assertEqual("false", environment["GIT_CONFIG_VALUE_0"])
        self.assertEqual("https://github.com/", environment["GIT_CONFIG_VALUE_1"])


if __name__ == "__main__":
    unittest.main()

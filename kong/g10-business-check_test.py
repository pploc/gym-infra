#!/usr/bin/env python3
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parent


class G10BusinessCheckTest(unittest.TestCase):
    def test_given_all_negative_probes_pass_when_script_runs_then_stdout_is_yaml_only(self):
        # given
        with tempfile.TemporaryDirectory() as directory:
            bin_dir = Path(directory) / "bin"
            bin_dir.mkdir()
            curl = bin_dir / "curl"
            curl.write_text("#!/bin/sh\ncase \"$*\" in\n  */api/v1/users/me) printf '%s\\n' 401 ;;\n  *) printf '%s\\n' 404 ;;\nesac\n")

            curl.chmod(0o700)
            raw = Path(directory) / "raw.yaml"
            environment = os.environ | {
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "G10_RAW_EVIDENCE": str(raw),
                "G10_BASE_URL": "https://fixture.invalid",
                "G10_CA_CERT": str(Path(directory) / "ca.crt"),
            }

            # when
            result = subprocess.run(
                [str(ROOT / "g10-business-check.sh")],
                capture_output=True,
                text=True,
                env=environment,
                check=False,
            )

            # then
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual("", result.stdout)
            self.assertIn("route_and_auth_negative_matrix", raw.read_text())


if __name__ == "__main__":
    unittest.main()

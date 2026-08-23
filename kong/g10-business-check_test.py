#!/usr/bin/env python3
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).parent


class G10BusinessCheckTest(unittest.TestCase):
    def test_given_negative_probes_pass_when_fixture_skipped_then_stdout_is_safe_yaml(self):
        # given
        with tempfile.TemporaryDirectory() as directory:
            bin_dir = Path(directory) / "bin"
            bin_dir.mkdir()
            curl = bin_dir / "curl"
            curl.write_text(
                "#!/bin/sh\n"
                "case \"$*\" in\n"
                "  */api/v1/users/me|*/api/v1/check-ins/me|*check-in-qr*) printf '%s\\n' 401 ;;\n"
                "  *) printf '%s\\n' 404 ;;\n"
                "esac\n"
            )
            curl.chmod(0o700)
            environment = os.environ | {
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "G10_BASE_URL": "https://fixture.invalid",
                "G10_CA_CERT": str(Path(directory) / "ca.crt"),
                "G10_SKIP_FIXTURE": "1",
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
            evidence = yaml.safe_load(result.stdout)
            names = [check["name"] for check in evidence["checks"]]
            self.assertEqual(["route_and_auth_negative_matrix"], names)
            self.assertIn("missing_jwt_checkins_me", result.stderr)
            self.assertIn("G10 business matrix passed.", result.stderr)


if __name__ == "__main__":
    unittest.main()

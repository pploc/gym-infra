#!/usr/bin/env python3
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml

ROOT = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("render_g11_config", ROOT / "render-g11-config.py")
RENDER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(RENDER)


class RenderG11ConfigTest(unittest.TestCase):
    def test_given_g11_template_when_rendered_then_webhook_is_exact_post_and_jwt_exempt(self):
        # given
        manifest = {"operations": []}
        for owner, count in RENDER.G10.EXPECTED.items():
            for index in range(count):
                manifest["operations"].append({
                    "selector": f"{owner}.v1.Service.Method{index}",
                    "operation_id": f"{owner}_{index}",
                    "method": "GET",
                    "path": f"/api/v1/{owner}/{index}",
                    "auth": "customer-self-from-verified-sub" if owner == "checkin" and index < 2 else "super-admin-only" if owner == "checkin" else "authenticated",
                })
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            manifest_path = path / "manifest.json"
            manifest_path.write_text(json.dumps(manifest))
            certs = path / "certs"
            certs.mkdir()
            (certs / "kong.crt").write_text("CERT")
            (certs / "kong.key").write_text("PRIVATE KEY")
            (certs / "g11-ca.crt").write_text("CA")
            output = path / "kong.yml"

            # when
            with patch("sys.argv", ["render-g11-config.py", "--manifest", str(manifest_path), "--template", str(ROOT / "g11-kong-template.yml"), "--cert-dir", str(certs), "--output", str(output)]):
                self.assertEqual(0, RENDER.main())
            config = yaml.safe_load(output.read_text())

        # then
        payment = next(service for service in config["services"] if service["name"] == "ms-gym-payment-webhook")
        self.assertEqual(["POST"], payment["routes"][0]["methods"])
        self.assertEqual(["~/api/v1/payments/webhook/sepay$"], payment["routes"][0]["paths"])
        self.assertTrue(payment["routes"][0]["request_buffering"])
        protected = next(plugin for plugin in config["plugins"] if plugin["name"] == "gym-jwt-claims")["config"]["protected_http_routes"]
        self.assertNotIn("payments/webhook", str(protected))


if __name__ == "__main__":
    unittest.main()

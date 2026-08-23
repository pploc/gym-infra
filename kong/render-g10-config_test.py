#!/usr/bin/env python3
import importlib.util
import os
import unittest
from copy import deepcopy
from pathlib import Path

import yaml

ROOT = Path(__file__).parent
PROTO_ROOT = Path(os.environ.get("G10_PROTO_ROOT", ROOT / "../../gym-proto"))
SPEC = importlib.util.spec_from_file_location("render_g10_config", ROOT / "render-g10-config.py")
RENDER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(RENDER)


class RenderG10ConfigTest(unittest.TestCase):
    def setUp(self):
        self.manifest = yaml.safe_load((PROTO_ROOT / "contracts/v1/http/active-operations.yaml").read_text())

    def test_given_released_manifest_when_validated_then_has_exact_checkin_routes(self):
        # given / when
        routes, protected = RENDER.given_manifest_when_validated_then_return_routes(self.manifest)

        # then
        self.assertEqual({owner: len(value) for owner, value in routes.items()}, {"identity": 12, "member": 7, "plans": 8, "checkin": 6})
        self.assertEqual(
            {(route["methods"][0], route["paths"][0]) for route in routes["checkin"]},
            {
                ("POST", r"~/api/v1/check\-ins:scan$"),
                ("GET", r"~/api/v1/check\-ins/me$"),
                ("GET", r"~/api/v1/members/[^/]+/check\-ins$"),
                ("GET", r"~/api/v1/gyms/[^/]+/check\-ins:daily\-count$"),
                ("GET", r"~/api/v1/gyms/[^/]+/check\-in\-qr$"),
                ("POST", r"~/api/v1/gyms/[^/]+/check\-in\-qr:rotate$"),
            },
        )
        self.assertEqual(len(protected), 27)

    def test_given_workload_selector_when_validated_then_reject(self):
        # given
        manifest = deepcopy(self.manifest)
        manifest["operations"][-1]["selector"] = "plans.v1.PlansService.ValidateCheckInGym"

        # when / then
        with self.assertRaisesRegex(ValueError, "retired or workload"):
            RENDER.given_manifest_when_validated_then_return_routes(manifest)

    def test_given_duplicate_method_path_when_validated_then_reject(self):
        # given
        manifest = deepcopy(self.manifest)
        manifest["operations"][-1]["path"] = manifest["operations"][-2]["path"]
        manifest["operations"][-1]["method"] = manifest["operations"][-2]["method"]

        # when / then
        with self.assertRaisesRegex(ValueError, "duplicate operation"):
            RENDER.given_manifest_when_validated_then_return_routes(manifest)


if __name__ == "__main__":
    unittest.main()

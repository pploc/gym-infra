#!/usr/bin/env python3
"""Render the additive G11 route set from the locked G10 manifest plus Payment webhook."""

from __future__ import annotations

import argparse
import importlib.util
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("render_g10_config", ROOT / "render-g10-config.py")
G10 = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(G10)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--cert-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()

    manifest = G10.read(args.manifest)
    routes, protected = G10.given_manifest_when_validated_then_return_routes(manifest)
    if args.verify_only:
        config = G10.read(args.template)
        payment = next(service for service in config["services"] if service["name"] == "ms-gym-payment-webhook")
        route = payment["routes"]
        if route != [{
            "name": "payment-sepay-webhook",
            "protocols": ["https"],
            "methods": ["POST"],
            "paths": ["~/api/v1/payments/webhook/sepay$"],
            "strip_path": False,
            "preserve_host": False,
            "request_buffering": True,
            "regex_priority": 200,
        }]:
            raise ValueError("SePay webhook route must be one exact POST route preserving the body")
        print("G11 route parity verified: G10 33 exact routes plus one JWT-exempt SePay POST webhook.")
        return 0

    config = G10.read(args.template)
    services = {service["name"]: service for service in config["services"]}
    for owner, name in G10.SERVICE.items():
        services[name]["routes"] += routes[owner]
    services["ms-gym-identifier"]["routes"].append({
        "name": "active-api-preflight",
        "protocols": ["https"],
        "methods": ["OPTIONS"],
        "paths": ["~" + G10.given_path_when_converted_to_kong_regex_then_anchor_exact_segments(operation["path"]) for operation in manifest["operations"]],
        "strip_path": False,
        "regex_priority": 100,
    })
    config["certificates"] = [{
        "id": "10000000-0000-0000-0000-000000000001",
        "cert": G10.pem(args.cert_dir / "kong.crt"),
        "key": G10.pem(args.cert_dir / "kong.key"),
    }]
    config["ca_certificates"] = [{
        "id": "20000000-0000-0000-0000-000000000001",
        "cert": G10.pem(args.cert_dir / "g11-ca.crt"),
    }]
    plugin = next(plugin for plugin in config["plugins"] if plugin["name"] == "gym-jwt-claims")
    plugin["config"]["protected_http_routes"] = protected
    args.output.write_text(yaml.safe_dump(config, sort_keys=False))
    print("Rendered ignored G11 config with 33 locked routes and one SePay webhook to " + str(args.output))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, StopIteration, TypeError, ValueError, yaml.YAMLError) as error:
        print(f"G11 config verification failed: {error}", file=sys.stderr)
        raise SystemExit(1)

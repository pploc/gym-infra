#!/usr/bin/env python3
"""Render G10 Kong routes only from released active-operation manifest."""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from pathlib import Path

import yaml

SERVICE = {
    "identity": "ms-gym-identifier",
    "member": "ms-gym-api-gateway",
    "plans": "ms-gym-api-gateway",
    "checkin": "ms-gym-api-gateway",
}
EXPECTED = {"identity": 12, "member": 7, "plans": 8, "checkin": 6}
ALLOWED_AUTH = {
    "public",
    "authenticated",
    "super-admin-only",
    "customer-self-or-super-admin",
    "customer-self-from-verified-sub",
    "customer-self",
}
CHECKIN_AUTH = Counter({"customer-self-from-verified-sub": 2, "super-admin-only": 4})
FORBIDDEN_SELECTOR_TOKENS = {
    "SelectGym",
    "GetMembershipStatusByUserId",
    "GetActiveGym",
    "ResolvePurchasablePlan",
    "ValidateMembership",
    "ValidateCheckInGym",
    "ListMembersByStatus",
}


def given_path_when_converted_to_kong_regex_then_anchor_exact_segments(path: str) -> str:
    parts = re.split(r"(\{[^}]+\})", path)
    return "".join("[^/]+" if part.startswith("{") else re.escape(part).replace(r"\:", ":") for part in parts) + "$"


def given_manifest_when_validated_then_return_routes(manifest: dict) -> tuple[dict[str, list[dict]], list[dict]]:
    operations = manifest.get("operations")
    if not isinstance(operations, list) or len(operations) != sum(EXPECTED.values()):
        raise ValueError(f"expected {sum(EXPECTED.values())} operations")

    counts: Counter[str] = Counter()
    checkin_auth: Counter[str] = Counter()
    selectors: set[str] = set()
    method_paths: set[tuple[str, str]] = set()
    routes = {owner: [] for owner in EXPECTED}
    protected: list[dict] = []

    for operation in operations:
        selector = operation.get("selector")
        method = operation.get("method")
        path = operation.get("path")
        auth = operation.get("auth")
        if not all(isinstance(value, str) and value for value in (selector, method, path, auth)):
            raise ValueError("operation fields are invalid")
        if selector in selectors or (method, path) in method_paths:
            raise ValueError(f"duplicate operation: {selector}")
        if any(token in selector for token in FORBIDDEN_SELECTOR_TOKENS):
            raise ValueError(f"retired or workload selector: {selector}")
        owner = selector.split(".", 1)[0]
        if owner not in EXPECTED:
            raise ValueError(f"unknown route owner: {selector}")
        if auth not in ALLOWED_AUTH:
            raise ValueError(f"unknown auth policy for {selector}: {auth}")
        if not path.startswith("/api/v1/"):
            raise ValueError(f"invalid public path for {selector}: {path}")
        selectors.add(selector)
        method_paths.add((method, path))
        counts[owner] += 1
        if owner == "checkin":
            checkin_auth[auth] += 1
        path_regex = given_path_when_converted_to_kong_regex_then_anchor_exact_segments(path)
        routes[owner].append({
            "name": operation["operation_id"].replace("_", "-").lower(),
            "protocols": ["https"],
            "methods": [method],
            "paths": ["~" + path_regex],
            "strip_path": False,
            "regex_priority": 100,
        })
        if auth != "public":
            protected.append({"method": method, "path_regex": "^" + path_regex})

    if counts != EXPECTED:
        raise ValueError(f"route ownership mismatch: {dict(counts)}")
    if checkin_auth != CHECKIN_AUTH:
        raise ValueError(f"Check-in auth mismatch: {dict(checkin_auth)}")
    return routes, protected


def read(path: Path) -> dict:
    value = yaml.safe_load(path.read_text())
    if not isinstance(value, dict):
        raise ValueError(f"invalid YAML document: {path}")
    return value


def pem(path: Path) -> str:
    value = path.read_text()
    if "PRIVATE KEY" in value and path.suffix != ".key":
        raise ValueError(f"private material in non-key input: {path}")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--cert-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()

    routes, protected = given_manifest_when_validated_then_return_routes(read(args.manifest))
    if args.verify_only:
        print("G10 manifest parity verified: 33 exact routes (12 identity, 7 member, 8 plans, 6 checkin).")
        return 0

    config = read(args.template)
    services = {service["name"]: service for service in config["services"]}
    for owner, name in SERVICE.items():
        if name not in services:
            raise ValueError(f"template has no service: {name}")
        services[name]["routes"] += routes[owner]
    services["ms-gym-identifier"]["routes"].append({
        "name": "active-api-preflight",
        "protocols": ["https"],
        "methods": ["OPTIONS"],
        "paths": ["~" + given_path_when_converted_to_kong_regex_then_anchor_exact_segments(operation["path"]) for operation in read(args.manifest)["operations"]],
        "strip_path": False,
        "regex_priority": 100,
    })
    config["certificates"] = [{
        "id": "10000000-0000-0000-0000-000000000001",
        "cert": pem(args.cert_dir / "kong.crt"),
        "key": pem(args.cert_dir / "kong.key"),
    }]
    config["ca_certificates"] = [{
        "id": "20000000-0000-0000-0000-000000000001",
        "cert": pem(args.cert_dir / "g10-ca.crt"),
    }]
    plugin = next(plugin for plugin in config["plugins"] if plugin["name"] == "gym-jwt-claims")
    plugin["config"]["protected_http_routes"] = protected
    args.output.write_text(yaml.safe_dump(config, sort_keys=False))
    print("Rendered ignored G10 config with 33 exact routes to " + str(args.output))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, TypeError, ValueError, yaml.YAMLError) as error:
        print(f"G10 config verification failed: {error}", file=sys.stderr)
        raise SystemExit(1)

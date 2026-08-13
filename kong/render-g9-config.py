#!/usr/bin/env python3
import argparse
import re
import sys
from pathlib import Path

import yaml

SERVICE = {
    "identity": "ms-gym-identifier",
    "member": "ms-gym-api-gateway",
    "plans": "ms-gym-api-gateway",
}
ALLOWED_AUTH = {
    "public",
    "authenticated",
    "super-admin-only",
    "customer-self-or-super-admin",
    "customer-self-from-verified-sub",
    "customer-self",
}
EXPECTED = {"identity": 12, "member": 7, "plans": 8}
EXPECTED_PUBLIC = {
    "identity.v1.IdentityService.Register",
    "identity.v1.IdentityService.Login",
    "identity.v1.IdentityService.LoginWithGoogle",
    "identity.v1.IdentityService.RefreshToken",
    "identity.v1.IdentityService.VerifyEmail",
    "identity.v1.IdentityService.ResendEmailVerification",
}
EXPECTED_AUTH = {
    "public": 6,
    "authenticated": 7,
    "super-admin-only": 8,
    "customer-self-or-super-admin": 3,
    "customer-self-from-verified-sub": 1,
    "customer-self": 2,
}
FORBIDDEN = {"SelectGym", "GetMembershipStatusByUserId", "GetActiveGym", "ResolvePurchasablePlan", "ValidateMembership", "ListMembersByStatus"}


def owner(selector: str) -> str:
    return selector.split(".", 1)[0]


def regex_path(path: str) -> str:
    parts = re.split(r"(\{[^}]+\})", path)
    return "".join("[^/]+" if p.startswith("{") else re.escape(p).replace(r"\:", ":") for p in parts) + "$"


def protected_regex(path_regex: str) -> str:
    return "^" + path_regex


def read(path: Path):
    return yaml.safe_load(path.read_text())


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

    operations = read(args.manifest)["operations"]
    if len(operations) != 27:
        raise ValueError(f"expected 27 operations, got {len(operations)}")
    counts = {key: 0 for key in EXPECTED}
    auth_counts = {auth: 0 for auth in ALLOWED_AUTH}
    selectors = set()
    public = set()
    protected = []
    routes = {key: [] for key in EXPECTED}
    for op in operations:
        selector = op["selector"]
        if selector in selectors or any(name in selector for name in FORBIDDEN):
            raise ValueError(f"duplicate or forbidden selector: {selector}")
        selectors.add(selector)
        key = owner(selector)
        if key not in EXPECTED:
            raise ValueError(f"unknown route owner: {selector}")
        counts[key] += 1
        auth = op["auth"]
        if auth not in ALLOWED_AUTH:
            raise ValueError(f"unknown auth policy for {selector}: {auth}")
        auth_counts[auth] += 1
        path_regex = regex_path(op["path"])
        route = {
            "name": op["operation_id"].replace("_", "-").lower(),
            "protocols": ["https"],
            "methods": [op["method"]],
            "paths": ["~" + path_regex],
            "strip_path": False,
            "regex_priority": 100,
        }
        routes[key].append(route)
        if auth == "public":
            public.add(selector)
        else:
            protected.append({"method": op["method"], "path_regex": protected_regex(path_regex)})
    if counts != EXPECTED:
        raise ValueError(f"route ownership mismatch: {counts}")
    if auth_counts != EXPECTED_AUTH or public != EXPECTED_PUBLIC:
        raise ValueError(f"auth policy mismatch: counts={auth_counts}, public={sorted(public)}")

    if args.verify_only:
        print("G9 manifest parity verified: 27 exact routes (12 identity, 7 member, 8 plans).")
        return 0

    config = read(args.template)
    by_name = {service["name"]: service for service in config["services"]}
    for key, name in SERVICE.items():
        by_name[name]["routes"] = by_name[name]["routes"] + routes[key]
    by_name["ms-gym-identifier"]["routes"].append({
        "name": "active-api-preflight",
        "protocols": ["https"],
        "methods": ["OPTIONS"],
        "paths": ["~" + regex_path(op["path"]) for op in operations],
        "strip_path": False,
        "regex_priority": 100,
    })

    cert_dir = args.cert_dir
    config["certificates"] = [{
        "id": "10000000-0000-0000-0000-000000000001",
        "cert": pem(cert_dir / "kong.crt"),
        "key": pem(cert_dir / "kong.key"),
    }]
    config["ca_certificates"] = [{
        "id": "20000000-0000-0000-0000-000000000001",
        "cert": pem(cert_dir / "g9-ca.crt"),
    }]
    plugin = next(p for p in config["plugins"] if p["name"] == "gym-jwt-claims")
    plugin["config"]["protected_http_routes"] = protected
    args.output.write_text(yaml.safe_dump(config, sort_keys=False))
    print(f"Rendered ignored G9 config with {len(operations)} exact routes to {args.output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, TypeError, ValueError, yaml.YAMLError) as exc:
        print(f"G9 config verification failed: {exc}", file=sys.stderr)
        raise SystemExit(1)

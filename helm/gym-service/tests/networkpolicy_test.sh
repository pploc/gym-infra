#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

helm template member "$root" -f "$root/examples/ms-gym-member-values.yaml" >"$work/member.yaml"
helm template plans "$root" -f "$root/examples/ms-gym-plans-values.yaml" >"$work/plans.yaml"

python3 - "$work/member.yaml" "$work/plans.yaml" <<'PY'
import sys, yaml

def policy(path):
    docs = list(yaml.safe_load_all(open(path)))
    return next(d for d in docs if d and d.get("kind") == "NetworkPolicy")

def edges(doc):
    result = set()
    for rule in doc["spec"]["ingress"]:
        ports = tuple(p["port"] for p in rule.get("ports", []))
        for peer in rule.get("from", []):
            selector = peer.get("podSelector", {}).get("matchLabels", {}).get("app.kubernetes.io/name")
            namespace = peer.get("namespaceSelector", {}).get("matchLabels", {}).get("kubernetes.io/metadata.name")
            result.add((selector or "namespace:" + str(namespace), ports))
    return result

member = edges(policy(sys.argv[1]))
plans = edges(policy(sys.argv[2]))
# Given active examples, when rendered, then callers have exact peer-to-port edges.
assert member == {
    ("ms-gym-api-gateway", (50051,)), ("ms-gym-checkin", (50051,)), ("ms-gym-notification", (50051,)),
    ("namespace:monitoring", (8080, 9090)),
}, member
assert plans == {
    ("ms-gym-api-gateway", (50051,)), ("ms-gym-identifier", (50051,)), ("ms-gym-member", (50051,)),
    ("namespace:monitoring", (8080, 9090)),
}, plans
assert all(selector != "kong" for selector, _ in member | plans), member | plans
assert all(not (selector == "ms-gym-api-gateway" and 8080 in ports) for selector, ports in member | plans), member | plans
PY

printf '%s\n' 'Member and Plans NetworkPolicy peer/port assertions passed.'

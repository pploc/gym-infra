#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

helm template member "$root" -f "$root/examples/ms-gym-member-values.yaml" >"$work/member.yaml"
helm template plans "$root" -f "$root/examples/ms-gym-plans-values.yaml" >"$work/plans.yaml"
helm template checkin "$root" -f "$root/examples/ms-gym-checkin-values.yaml" >"$work/checkin.yaml"
helm template payment "$root" -f "$root/examples/ms-gym-payment-values.yaml" >"$work/payment.yaml"
helm template trainer "$root" -f "$root/examples/ms-gym-trainer-values.yaml" >"$work/trainer.yaml"

python3 - "$work/member.yaml" "$work/plans.yaml" "$work/checkin.yaml" "$work/payment.yaml" "$work/trainer.yaml" <<'PY'
import sys, yaml


def documents(path):
    with open(path) as source:
        return [document for document in yaml.safe_load_all(source) if document]


def policy(path, suffix="-network-policy"):
    return next(document for document in documents(path) if document.get("kind") == "NetworkPolicy" and document["metadata"]["name"].endswith(suffix))


def selector(peer):
    pod = peer.get("podSelector", {}).get("matchLabels", {}).get("app.kubernetes.io/name")
    namespace = peer.get("namespaceSelector", {}).get("matchLabels", {}).get("kubernetes.io/metadata.name")
    return pod or "namespace:" + str(namespace)


def edges(rules, direction):
    result = set()
    for rule in rules:
        ports = tuple((port["protocol"], port["port"]) for port in rule.get("ports", []))
        for peer in rule.get(direction, []):
            result.add((selector(peer), ports))
    return result


member = edges(policy(sys.argv[1])["spec"]["ingress"], "from")
plans = edges(policy(sys.argv[2])["spec"]["ingress"], "from")
checkin_policy = policy(sys.argv[3])
checkin_ingress = edges(checkin_policy["spec"]["ingress"], "from")
checkin_egress = edges(checkin_policy["spec"]["egress"], "to")
payment_policy = policy(sys.argv[4])
payment_ingress = edges(payment_policy["spec"]["ingress"], "from")
payment_egress = edges(payment_policy["spec"]["egress"], "to")
trainer_policy = policy(sys.argv[5])
trainer_ingress = edges(trainer_policy["spec"]["ingress"], "from")
trainer_egress = edges(trainer_policy["spec"]["egress"], "to")

# Given active examples, when rendered, then callers have exact peer-to-port edges.
assert member == {
    ("ms-gym-api-gateway", (("TCP", 50051),)), ("ms-gym-checkin", (("TCP", 50051),)),
    ("ms-gym-notification", (("TCP", 50051),)), ("namespace:monitoring", (("TCP", 8080), ("TCP", 9090))),
}, member
assert plans == {
    ("ms-gym-api-gateway", (("TCP", 50051),)), ("ms-gym-identifier", (("TCP", 50051),)),
    ("ms-gym-member", (("TCP", 50051),)), ("ms-gym-checkin", (("TCP", 50051),)),
    ("namespace:monitoring", (("TCP", 8080), ("TCP", 9090))),
}, plans
assert checkin_ingress == {
    ("ms-gym-api-gateway", (("TCP", 50051),)), ("namespace:monitoring", (("TCP", 8080),)),
}, checkin_ingress
assert checkin_egress == {
    ("namespace:kube-system", (("UDP", 53), ("TCP", 53))), ("ms-gym-member", (("TCP", 50051),)),
    ("ms-gym-plans", (("TCP", 50051),)), ("yugabyte", (("TCP", 5433),)),
    ("kafka", (("TCP", 9092),)), ("schema-registry", (("TCP", 8081),)),
}, checkin_egress
assert payment_ingress == {
    ("ms-gym-member", (("TCP", 50051),)), ("kong", (("TCP", 8080),)),
    ("namespace:monitoring", (("TCP", 8080), ("TCP", 9090))),
}, payment_ingress
assert payment_egress == {
    ("namespace:kube-system", (("UDP", 53), ("TCP", 53))), ("postgres", (("TCP", 5432),)),
    ("kafka", (("TCP", 9092),)), ("schema-registry", (("TCP", 8081),)),
}, payment_egress
assert trainer_ingress == {
    ("ms-gym-api-gateway", (("TCP", 50051),)),
    ("namespace:monitoring", (("TCP", 8080), ("TCP", 9090))),
}, trainer_ingress
assert trainer_egress == {
    ("namespace:kube-system", (("UDP", 53), ("TCP", 53))),
    ("ms-gym-identifier", (("TCP", 50051),)),
    ("ms-gym-plans", (("TCP", 50051),)),
    ("postgres", (("TCP", 5432),)),
}, trainer_egress
assert "Egress" in checkin_policy["spec"]["policyTypes"]
assert "Egress" in payment_policy["spec"]["policyTypes"]
assert "Egress" in trainer_policy["spec"]["policyTypes"]
assert all(selector != "kong" for selector, _ in member | plans | checkin_ingress | trainer_ingress), member | plans | checkin_ingress | trainer_ingress
assert all(not (selector == "ms-gym-api-gateway" and ("TCP", 8080) in ports) for selector, ports in member | plans | checkin_ingress | trainer_ingress)
assert all(("TCP", 9090) not in ports for _, ports in checkin_ingress | checkin_egress | payment_egress | trainer_egress)
assert all(selector not in {"kafka", "schema-registry", "ms-gym-payment", "ms-gym-notification", "ms-gym-analytics"} for selector, _ in trainer_egress)
PY

printf '%s\n' 'Member, Plans, Check-in, Payment, and Trainer NetworkPolicy peer/port assertions passed.'

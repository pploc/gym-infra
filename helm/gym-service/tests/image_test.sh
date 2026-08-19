#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

helm template checkin "$root" \
  -f "$root/examples/ms-gym-checkin-values.yaml" \
  --set image.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  >"$work/digest.yaml"
helm template checkin "$root" \
  -f "$root/examples/ms-gym-checkin-values.yaml" \
  >"$work/tag.yaml"

python3 - "$work/digest.yaml" "$work/tag.yaml" <<'PY'
import sys
import yaml


def deployment(path):
    with open(path) as source:
        return next(
            document for document in yaml.safe_load_all(source)
            if document and document.get("kind") == "Deployment"
        )


digest = deployment(sys.argv[1])["spec"]["template"]["spec"]["containers"][0]["image"]
tag = deployment(sys.argv[2])["spec"]["template"]["spec"]["containers"][0]["image"]
assert digest == "ghcr.io/pploc/ms-gym-checkin@sha256:" + "a" * 64, digest
assert tag == "ghcr.io/pploc/ms-gym-checkin:27e9f71ce12f6dc4b47b35614dc562ceb2651de1", tag
PY

printf '%s\n' 'Helm digest and tag image rendering assertions passed.'

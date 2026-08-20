#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
lock=$root/g10-release-lock.json
workspace=$(mktemp -d "${TMPDIR:-/tmp}/gym-g10.XXXXXX")
paths=$(mktemp "${TMPDIR:-/tmp}/gym-g10-paths.XXXXXX")
raw=$root/g10-raw-evidence.yaml
safe=$root/g10-sanitized-evidence.yaml
compose="docker compose -f $root/g10-compose.yml"

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required for locked source materialization}"

cleanup() {
  result=$?
  $compose down --remove-orphans >/dev/null 2>&1 || true
  rm -f "$paths" "$raw"
  rm -rf "$workspace" "$root/g10-certs" "$root/g10-rendered-kong.yml"
  exit "$result"
}
failed() {
  printf '%s\n' 'G10 locked E2E failed.' >&2
  exit 1
}
trap cleanup EXIT INT TERM

python3 "$root/validate-g10-lock.py" "$lock"
python3 "$root/materialize-g10.py" --lock "$lock" --workspace "$workspace" >"$paths" || failed
. "$paths"

python3 - "$lock" "$G10_INFRA_ROOT" "$root" <<'PY'
import hashlib, json, os, subprocess, sys
from pathlib import Path
lock_path, infra_root, fixture = map(Path, sys.argv[1:])
lock = json.loads(lock_path.read_text())
if subprocess.check_output(["git", "-C", str(infra_root), "rev-parse", "HEAD"], text=True).strip() != lock["repositories"]["infrastructure"]["sha"]:
    raise SystemExit("infrastructure source SHA mismatch")
checks = {
    "compose": fixture / "g10-compose.yml",
    "certGenerator": fixture / "generate-g10-certs.sh",
    "gatewayGoMod": fixture / "generated-gateway/go.mod",
    "gatewayGoSum": fixture / "generated-gateway/go.sum",
    "migration": Path(os.environ["G10_CHECKIN_ROOT"]) / "migrations/001_init.sql",
}
for name, path in checks.items():
    if hashlib.sha256(path.read_bytes()).hexdigest() != lock["checksums"][name]:
        raise SystemExit(f"{name} checksum mismatch")
PY

"$root/generate-g10-certs.sh" "$root/g10-certs"
find "$root/g10-certs" -type f -name '*.key' -perm /0077 -print -quit | grep -q . && failed || true
python3 "$root/render-g10-config.py" \
  --manifest "$G10_PROTO_ROOT/contracts/v1/http/active-operations.yaml" \
  --template "$root/g10-kong-template.yml" \
  --cert-dir "$root/g10-certs" \
  --output "$root/g10-rendered-kong.yml" || failed

eval "$(python3 - "$lock" <<'PY'
import json, shlex, sys
images = json.load(open(sys.argv[1]))["images"]
for name, image in images.items():
    env = {"schemaRegistry": "SCHEMA_REGISTRY", "gateway": "GATEWAY"}.get(name, name).upper()
    print(f"export G10_{env}_IMAGE={shlex.quote(image)}")
print(f"export G10_POSTGRES_IMAGE={shlex.quote(images['postgres'])}")
print(f"export G10_REDIS_IMAGE={shlex.quote(images['redis'])}")
PY
)"
export G10_CHECKIN_DATABASE_URL='postgres://yugabyte@yugabyte:5433/checkin_db?sslmode=disable'
$compose config --quiet || failed
$compose up -d || failed

for _ in $(seq 1 300); do
  if curl -fsS https://localhost:8443/status --cacert "$root/g10-certs/g10-ca.crt" >/dev/null 2>&1; then
    "$root/g10-business-check.sh" >"$raw" || failed
    python3 "$root/sanitize-g10-evidence.py" "$raw" "$safe" || failed
    printf '%s\n' 'G10 locked E2E and sanitized evidence passed.'
    exit 0
  fi
  sleep 1
done
failed

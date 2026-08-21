#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
lock=$root/g10-release-lock.json
workspace_parent=$(mktemp -d "${TMPDIR:-/tmp}/gym-g10-parent.XXXXXX")
workspace=$workspace_parent/source
paths=$(mktemp "${TMPDIR:-/tmp}/gym-g10-paths.XXXXXX")
# materialize-g10.py creates absent workspace with mode 0700.

compose=""
raw=""
safe=""
fixture=""
rendered=""
certs=""
diagnostics=$root/g10-last-run.log
rm -f "$diagnostics" "$root/g10-raw-evidence.yaml" "$root/g10-rendered-kong.yml"


: "${GITHUB_TOKEN:?GITHUB_TOKEN is required for locked source materialization}"

cleanup() {
  result=$?
  [ -z "$compose" ] || $compose down --remove-orphans >/dev/null 2>&1 || true
  rm -f "$paths" "$safe"
  rm -rf "$workspace_parent" "$certs"
  exit "$result"
}
failed() {
  printf '%s\n' 'G10 locked E2E failed.' >&2
  {
    printf '%s\n' 'G10 locked E2E failed.'
    [ -z "$compose" ] || $compose ps || true
  } >"$diagnostics"
  [ -z "$compose" ] || $compose ps >&2 || true
  exit 1
}
trap cleanup EXIT INT TERM

python3 "$root/validate-g10-lock.py" "$lock"
python3 "$root/materialize-g10.py" --lock "$lock" --workspace "$workspace" >"$paths" || failed
. "$paths"
export G10_PROTO_ROOT
fixture=$G10_INFRA_ROOT/kong
lock=$root/g10-release-lock.json
compose="docker compose -f $fixture/g10-compose.yml"

raw=$fixture/g10-raw-evidence.yaml
safe=$fixture/g10-sanitized-evidence.yaml
certs=$fixture/g10-certs
rendered=$fixture/g10-rendered-kong.yml

python3 - "$lock" "$G10_INFRA_ROOT" "$fixture" <<'PY'
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

"$fixture/generate-g10-certs.sh" "$certs"
find "$certs" -type f -name '*.key' -perm /0077 -print -quit | grep -q . && failed || true
python3 "$fixture/render-g10-config.py" \
  --manifest "$G10_PROTO_ROOT/contracts/v1/http/active-operations.yaml" \
  --template "$fixture/g10-kong-template.yml" \
  --cert-dir "$certs" \
  --output "$rendered" || failed

eval "$(python3 - "$lock" <<'PY'
import json, shlex, sys
images = json.load(open(sys.argv[1]))["images"]
for name, image in images.items():
    env = {"schemaRegistry": "SCHEMA_REGISTRY", "gateway": "GATEWAY", "yugabyte": "YUGABYTE", "localstack": "LOCALSTACK", "kafka": "KAFKA", "kong": "KONG", "postgres": "POSTGRES", "redis": "REDIS"}.get(name, name).upper()
    print(f"export G10_{env}_IMAGE={shlex.quote(image)}")
PY
)"
export G10_CHECKIN_DATABASE_URL='postgres://yugabyte@yugabyte:5433/checkin_db?sslmode=disable'
$compose config --quiet || failed
$compose up -d || failed

for _ in $(seq 1 300); do
  if $compose ps --status running --services | grep -qx kong \
      && $compose ps --status running --services | grep -qx ms-gym-api-gateway \
      && $compose ps --status running --services | grep -qx ms-gym-checkin; then
    if curl --cacert "$certs/g10-ca.crt" -sS -o /dev/null \
        -w '%{http_code}' https://localhost:8443/status | grep -qx 404; then
      "$fixture/g10-business-check.sh" >"$raw" || failed
      python3 "$fixture/sanitize-g10-evidence.py" "$raw" "$safe" || failed
      printf '%s\n' 'G10 locked E2E and sanitized evidence passed.'
      exit 0
    fi
  fi
  sleep 1
done
failed

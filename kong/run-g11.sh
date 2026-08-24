#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
lock=$root/g11-release-lock.json
: "${G11_SEPAY_WEBHOOK_SECRET:=$(python3 -c 'import secrets; print(secrets.token_hex(32))')}"
export G11_SEPAY_WEBHOOK_SECRET

workspace_parent=$(mktemp -d "${TMPDIR:-/tmp}/gym-g11-parent.XXXXXX")
workspace=$workspace_parent/source
paths=$(mktemp "${TMPDIR:-/tmp}/gym-g11-paths.XXXXXX")
certs=$root/g11-certs
rendered=$root/g11-rendered-kong.yml
raw=$root/g11-raw-evidence.yaml
safe=$root/g11-sanitized-evidence.yaml
logs=$root/g11-last-run.log
compose=""
compose_ready=0

cleanup() {
  result=$?
  [ "$compose_ready" -ne 1 ] || $compose down --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$workspace_parent" "$paths" "$certs" "$rendered"
  exit "$result"
}
failed() {
  printf '%s\n' 'G11 locked E2E failed.' >&2
  {
    printf '%s\n' 'G11 locked E2E failed.'
    [ "$compose_ready" -ne 1 ] || $compose ps || true
    [ "$compose_ready" -ne 1 ] || $compose logs --no-color --tail=200 payment-postgres ms-gym-payment ms-gym-member kong || true
  } >"$logs"
  exit 1
}
trap cleanup EXIT INT TERM
rm -f "$raw" "$safe" "$logs"

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required for locked source materialization}"
python3 "$root/validate-g11-lock.py" "$lock" || failed
python3 "$root/materialize-g11.py" --lock "$lock" --workspace "$workspace" >"$paths" || failed
. "$paths"
export G11_PROTO_ROOT G11_IDENTIFIER_ROOT G11_MEMBER_ROOT G11_PLANS_ROOT G11_CHECKIN_ROOT G11_PAYMENT_ROOT

[ "$(git -C "$G11_INFRA_ROOT" rev-parse HEAD)" = "$(python3 - "$lock" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["repositories"]["infrastructure"]["sha"])
PY
)" ] || failed
"$root/generate-g11-certs.sh" "$certs" || failed
python3 "$root/render-g11-config.py" --manifest "$G11_PROTO_ROOT/contracts/v1/http/active-operations.yaml" --template "$root/g11-kong-template.yml" --cert-dir "$certs" --output "$rendered" || failed

eval "$(python3 - "$lock" <<'PY'
import json,shlex,sys
for name,image in json.load(open(sys.argv[1]))["images"].items():
    if image is not None:
        env={"schemaRegistry":"SCHEMA_REGISTRY","schemaSeed":"SCHEMA_SEED"}.get(name,name).upper()
        print(f"export G11_{env}_IMAGE={shlex.quote(image)}")
PY
)"
export G11_CHECKIN_DATABASE_URL='postgres://yugabyte@yugabyte:5433/checkin_db?sslmode=disable'
compose="docker compose -f $root/g11-compose.yml"
$compose config --quiet || failed
compose_ready=1
$compose up -d --build || failed

for _ in $(seq 1 300); do
  if $compose ps --status running --services | grep -qx kong && $compose exec -T kong kong health >/dev/null 2>&1; then
    "$root/g11-business-check.sh" >"$raw" || failed
    python3 "$root/sanitize-g11-evidence.py" "$lock" "$raw" "$safe" || failed
    printf '%s\n' 'G11 locked E2E and sanitized evidence passed.'
    exit 0
  fi
  sleep 1
done
failed

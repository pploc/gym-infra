#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
lock=$root/g10-release-lock.json
workspace_parent=$(mktemp -d "${TMPDIR:-/tmp}/gym-g10-parent.XXXXXX")
workspace=$workspace_parent/source
paths=$(mktemp "${TMPDIR:-/tmp}/gym-g10-paths.XXXXXX")
# materialize-g10.py creates absent workspace with mode 0700.

compose=""
compose_ready=0
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
  [ "$compose_ready" -ne 1 ] || $compose down --remove-orphans >/dev/null 2>&1 || true
  rm -f "$paths" "$safe"
  rm -rf "$workspace_parent" "$certs"
  exit "$result"
}
phase() {
  printf '%s\n' "G10 phase: $1"
}
failed() {
  printf '%s\n' 'G10 locked E2E failed.' >&2
  {
    printf '%s\n' 'G10 locked E2E failed.'
    [ "$compose_ready" -ne 1 ] || $compose ps || true
    [ "$compose_ready" -ne 1 ] || $compose logs --no-color --tail=200 plans-migrate member-migrate identifier-migrate checkin-migrate kms-init kafka schema-registry ms-gym-plans ms-gym-member ms-gym-identifier ms-gym-checkin ms-gym-api-gateway kong || true
  } >"$diagnostics"
  [ "$compose_ready" -ne 1 ] || $compose ps >&2 || true
  [ "$compose_ready" -ne 1 ] || $compose logs --no-color --tail=200 plans-migrate member-migrate identifier-migrate checkin-migrate kms-init kafka schema-registry ms-gym-plans ms-gym-member ms-gym-identifier ms-gym-checkin ms-gym-api-gateway kong >&2 || true
  exit 1
}
trap cleanup EXIT INT TERM

phase lock-validation
python3 "$root/validate-g10-lock.py" "$lock"
phase source-materialization
timeout 180 python3 "$root/materialize-g10.py" --lock "$lock" --workspace "$workspace" >"$paths" || failed
. "$paths"
export G10_PROTO_ROOT
fixture=$G10_INFRA_ROOT/kong
lock=$root/g10-release-lock.json
compose="docker compose -f $fixture/g10-compose.yml"

raw=$fixture/g10-raw-evidence.yaml
safe=$fixture/g10-sanitized-evidence.yaml
certs=$fixture/g10-certs
rendered=$fixture/g10-rendered-kong.yml

phase source-verification
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

phase certificate-generation
"$fixture/generate-g10-certs.sh" "$certs"
find "$certs" -path "$certs/runtime" -prune -o -type f -name '*.key' -perm /0077 -print -quit | grep -q . && failed || true
find "$certs/runtime" -type f -name '*.key' ! -perm -0004 -print -quit | grep -q . && failed || true
phase kong-rendering
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
print(f"export G10_GATEWAY_IMAGE={shlex.quote(images['gateway'])}")
print(f"export G10_LOCALSTACK_IMAGE={shlex.quote(images['localstack'])}")
print(f"export G10_SCHEMA_REGISTRY_IMAGE={shlex.quote(images['schemaRegistry'])}")
print(f"export G10_POSTGRES_IMAGE={shlex.quote(images['postgres'])}")
print(f"export G10_REDIS_IMAGE={shlex.quote(images['redis'])}")
print(f"export G10_YUGABYTE_IMAGE={shlex.quote(images['yugabyte'])}")
print(f"export G10_KAFKA_IMAGE={shlex.quote(images['kafka'])}")
print(f"export G10_KONG_IMAGE={shlex.quote(images['kong'])}")
print(f"export G10_IDENTIFIER_IMAGE={shlex.quote(images['identifier'])}")
print(f"export G10_MEMBER_IMAGE={shlex.quote(images['member'])}")
print(f"export G10_PLANS_IMAGE={shlex.quote(images['plans'])}")
print(f"export G10_CHECKIN_IMAGE={shlex.quote(images['checkin'])}")
PY
)"
export G10_CHECKIN_DATABASE_URL='postgres://yugabyte@yugabyte:5433/checkin_db?sslmode=disable'
phase compose-validation
$compose config --quiet || failed
compose_ready=1
phase compose-startup
timeout 180 $compose up -d || failed

phase runtime-readiness
for _ in $(seq 1 300); do
  if $compose ps --status running --services | grep -qx kong \
      && $compose ps --status running --services | grep -qx ms-gym-api-gateway \
      && $compose ps --status running --services | grep -qx ms-gym-checkin; then
    if curl --cacert "$certs/g10-ca.crt" -sS -o /dev/null \
        -w '%{http_code}' https://localhost:8443/status | grep -qx 404; then
      phase business-validation
      "$fixture/g10-business-check.sh" >"$raw" || failed
      phase evidence-sanitization
      python3 "$fixture/sanitize-g10-evidence.py" "$raw" "$safe" || failed
      printf '%s\n' 'G10 locked E2E and sanitized evidence passed.'
      exit 0
    fi
  fi
  sleep 1
done
failed

#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/gym-g9.XXXXXX")
rmdir "$workspace"
paths=$(mktemp "${TMPDIR:-/tmp}/gym-g9-paths.XXXXXX")
proto_root=
g9_compose="docker compose -f $root/g9-compose.yml"
plugin_compose="docker compose -f $root/docker-compose.yml"
observed=$root/g9-observed-errors.yaml
sanitized=$root/g9-sanitized-evidence.yaml
lock=$root/g9-release-lock.json
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required to build private dependencies}"

cleanup() {
  $g9_compose down --remove-orphans >/dev/null 2>&1 || true
  $plugin_compose down --remove-orphans >/dev/null 2>&1 || true
  docker logout ghcr.io >/dev/null 2>&1 || true
  rm -f "$paths"
  rm -rf "$workspace" "$root/g9-certs" "$root/g9-proto" "$root/g9-release-assets" "$root/g9-rendered-kong.yml" \
    "$root/g9-private" "$root/g9-business-status"
}
failed() {
  {
    printf '%s\n' '=== G9 fixture ==='
    $g9_compose ps -a || true
    $g9_compose logs --no-color || true
    printf '%s\n' '=== Kong plugin fixture ==='
    $plugin_compose ps -a || true
    $plugin_compose logs --no-color || true
  } >"$root/g9-last-run.log" 2>&1
  cleanup
  exit 1
}
trap cleanup EXIT INT TERM

python3 -c 'import yaml' || {
  printf '%s\n' 'PyYAML is required; install PyYAML==6.0.3 before running G9.' >&2
  exit 1
}
helm lint "$root/../helm/gym-service"
"$root/../helm/gym-service/tests/networkpolicy_test.sh"

$plugin_compose config >/dev/null || failed
$plugin_compose up -d --build || failed
for _ in $(seq 1 60); do
  if curl -fsS http://localhost:8001/status >/dev/null 2>&1; then
    (cd "$root/tests" && go test -v ./...) || failed
    break
  fi
  sleep 1
done
curl -fsS http://localhost:8001/status >/dev/null 2>&1 || {
  printf '%s\n' 'Kong plugin fixture did not become ready within 60 seconds.' >&2
  failed
}
$plugin_compose down --remove-orphans || failed

rm -f "$observed" "$sanitized"
python3 "$root/validate-g9-lock.py" "$lock"
python3 "$root/materialize-g9.py" --lock "$lock" --workspace "$workspace" > "$paths"
# materialize-g9.py emits shell-quoted paths only.
# shellcheck disable=SC1090
. "$paths"
proto_root=$G9_PROTO_ROOT
python3 - "$lock" "$proto_root" "$root" "$G9_IDENTIFIER_ROOT" "$G9_MEMBER_ROOT" "$G9_PLANS_ROOT" <<'PY'
import hashlib
import json
import subprocess
import sys
import urllib.request
from urllib.parse import urlparse
from pathlib import Path

lock_path, proto_root, root, identifier_root, member_root, plans_root = map(Path, sys.argv[1:])
lock = json.loads(lock_path.read_text())

def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def require(value, message):
    if not value:
        raise SystemExit(message)

require(
    subprocess.check_output(["git", "-C", proto_root, "rev-parse", "HEAD"], text=True).strip() == lock["gymProto"]["sourceSha"],
    "gym-proto source does not match g9 release lock",
)
require(sha256(proto_root / "contracts/v1/http/active-operations.yaml") == lock["routes"]["manifestSha256"], "route manifest checksum mismatch")
require(sha256(root / "g9-kong-template.yml") == lock["routes"]["templateSha256"], "Kong template checksum mismatch")
require((root / "g9-compose.yml").read_text().count(lock["kong"]["image"]) == 1, "Kong image is not pinned to g9 release lock")
require(lock["dependencies"]["javaProto"] in (proto_root / "contracts/v1/manifest.json").read_text(), "Java contract version mismatch")

for name, service_root in (("ms-gym-member", member_root), ("ms-gym-plans", plans_root)):
    build = (service_root / "build.gradle").read_text()
    require(f"com.gym.proto:gym-proto-java:{lock['dependencies']['javaProto']}" in build, f"{name} does not use released Java contract")

for module in (identifier_root, root / "generated-gateway", root / "fixtures/fake-payment"):
    listing = subprocess.check_output(["go", "list", "-m", "github.com/pploc/proto-go"], cwd=module, text=True).strip()
    require(listing.endswith(lock["dependencies"]["goProto"]), f"{module} does not use released Go contract")
    require("replace github.com/pploc/proto-go" not in (module / "go.mod").read_text(), f"{module} has local Go contract replacement")

gateway = lock["gateway"]
require(sha256(root / "generated-gateway/go.mod") == gateway["goModSha256"], "gateway go.mod checksum mismatch")
require(sha256(root / "generated-gateway/go.sum") == gateway["goSumSha256"], "gateway go.sum checksum mismatch")
require(sha256(root / "fixtures/fake-payment/go.mod") == gateway["fakePaymentGoModSha256"], "fake payment go.mod checksum mismatch")
require(sha256(root / "fixtures/fake-payment/go.sum") == gateway["fakePaymentGoSumSha256"], "fake payment go.sum checksum mismatch")

kong_proto = lock["artifacts"]["kongProto"]
assets = {Path(urlparse(kong_proto["url"]).path).name: (kong_proto["url"], kong_proto["sha256"])}
assets.update({
    f"{name}.openapi.yaml": (
        f"https://github.com/pploc/gym-proto/releases/download/{lock['gymProto']['version']}/{name}.openapi.yaml",
        digest,
    )
    for name, digest in lock["artifacts"]["openApi"].items()
})
canonical_openapi = lock["artifacts"].get("canonicalOpenApi")
if canonical_openapi:
    assets["gym-active-api.openapi.yaml"] = (canonical_openapi["url"], canonical_openapi["sha256"])
asset_dir = root / "g9-release-assets"
asset_dir.mkdir(exist_ok=True)
for name, (url, expected) in assets.items():
    path = asset_dir / name
    urllib.request.urlretrieve(url, path)
    require(sha256(path) == expected, f"release asset checksum mismatch: {name}")
PY
set -- "$root"/g9-release-assets/kong-proto-*.tar.gz
[ "$#" -eq 1 ] || { printf '%s\n' 'Expected exactly one locked Kong proto archive.' >&2; failed; }
"$root/verify-openapi-types.sh" "$root/g9-release-assets/gym-active-api.openapi.yaml" || failed
rm -rf "$root/g9-proto"
mkdir -p "$root/g9-proto"
tar -xzf "$1" -C "$root/g9-proto" --strip-components=1
"$root/generate-g9-certs.sh" "$root/g9-certs"
"$root/render-g9-config.py" \
  --manifest "$proto_root/contracts/v1/http/active-operations.yaml" \
  --template "$root/g9-kong-template.yml" \
  --cert-dir "$root/g9-certs" --output "$root/g9-rendered-kong.yml"
G9_GATEWAY_IMAGE=$(python3 - "$lock" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1]))["gateway"]["image"])
PY
)
export G9_GATEWAY_IMAGE
printf '%s' "$GITHUB_TOKEN" | docker login ghcr.io -u "${GITHUB_ACTOR:-x-access-token}" --password-stdin >/dev/null || failed
$g9_compose config >/dev/null || failed
BUILDKIT_PROGRESS=quiet $g9_compose up -d --build || failed

for _ in $(seq 1 300); do
  if curl -fsS http://localhost:8001/status >/dev/null 2>&1; then
    "$root/g9-business-check.sh" || failed
    # This is the Stage 3 stop gate. It consumes business fixture IDs without persisting tokens.
    "$root/g9-compatibility-check.sh" "$observed" "$root/g9-business-status" || {
      cp "$observed" "$root/g9-last-run.log"
      exit 1
    }
    python3 "$root/sanitize-g9-evidence.py" "$observed" "$sanitized" || failed
    printf '%s\n' 'G9 Helm, NetworkPolicy, Kong plugin, compatibility, and sanitized-evidence gates passed.'
    exit 0
  fi
  sleep 1
done
printf '%s\n' 'Kong did not become ready within 300 seconds.' >&2
failed

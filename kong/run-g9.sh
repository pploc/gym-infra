#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
proto_root=$(CDPATH= cd -- "$root/../../gym-proto" && pwd)
g9_compose="docker compose -f $root/g9-compose.yml"
plugin_compose="docker compose -f $root/docker-compose.yml"
observed=$root/g9-observed-errors.yaml
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required to build private dependencies}"

cleanup() {
  $g9_compose down --remove-orphans >/dev/null 2>&1 || true
  $plugin_compose down --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$root/g9-certs" "$root/g9-proto" "$root/g9-rendered-kong.yml" \
    "$root/g9-private" "$root/g9-business-status" "$root/generated-gateway/proto-go"
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

rm -f "$observed"
(cd "$proto_root" && buf generate && ./gradlew verifyHttpConfig verifyOpenApi packageKongProto verifyKongProto --no-daemon)
(cd "$proto_root" && sha256sum -c dist/kong-proto-6.0.0.tar.gz.sha256)
rm -rf "$root/g9-proto" "$root/generated-gateway/proto-go"
mkdir -p "$root/g9-proto" "$root/generated-gateway/proto-go"
tar -xzf "$proto_root/dist/kong-proto-6.0.0.tar.gz" -C "$root/g9-proto" --strip-components=1
cp -R "$proto_root/gen/go/." "$root/generated-gateway/proto-go/"
cp "$root/generated-gateway/proto-go.mod" "$root/generated-gateway/proto-go/go.mod"
"$root/generate-g9-certs.sh" "$root/g9-certs"
"$root/render-g9-config.py" \
  --manifest "$proto_root/contracts/v1/http/active-operations.yaml" \
  --template "$root/g9-kong-template.yml" \
  --cert-dir "$root/g9-certs" --output "$root/g9-rendered-kong.yml"
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
    printf '%s\n' 'G9 Helm, NetworkPolicy, Kong plugin, and compatibility gates passed.'
    exit 0
  fi
  sleep 1
done
printf '%s\n' 'Kong did not become ready within 300 seconds.' >&2
failed

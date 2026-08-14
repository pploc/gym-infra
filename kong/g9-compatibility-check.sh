#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
compose="docker compose -f $root/g9-compose.yml"
out=${1:-"$root/g9-observed-errors.yaml"}
status_file=${2:-${G9_BUSINESS_STATUS_FILE:-"$root/g9-business-status"}}
base=${G9_BASE_URL:-https://localhost:8443}
origin=${G9_ORIGIN:-https://localhost:3000}
ca=${G9_CA_CERT:-"$root/g9-certs/g9-ca.crt"}
work=$(mktemp -d)
plans_stopped=false
plans_database_read_only=false
cleanup() {
  if [ "$plans_database_read_only" = true ]; then
    $compose exec -T plans-postgres psql -U postgres -d postgres -c 'ALTER DATABASE plans_db RESET default_transaction_read_only' >/dev/null 2>&1 || true
  fi
  if [ "$plans_stopped" = true ]; then
    $compose start ms-gym-plans >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
make_token() {
  role=$1 sub=${2:-00000000-0000-0000-0000-000000000001}
  now=$(date +%s)
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT","kid":"current"}' | b64url)
  payload=$(printf '{"iss":"gym-identifier","aud":"gym-api","sub":"%s","role":"%s","iat":%s,"exp":%s,"jti":"g9-compat-%s"}' \
    "$sub" "$role" "$now" "$((now + 3600))" "$role" | b64url)
  unsigned=$header.$payload
  signature=$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$root/certs/fixture_rsa.key" | b64url)
  printf '%s.%s' "$unsigned" "$signature"
}
super_admin_token=$(make_token SUPER_ADMIN)
invalid_role_token=$(make_token INVALID_ROLE)

json_string() {
  python3 -c 'import json,sys
value=sys.stdin.buffer.read().decode("utf-8", "strict")
print(json.dumps(value, ensure_ascii=True, separators=(",", ":")))'
}

yaml_string() {
  python3 -c 'import json,sys
value=sys.stdin.read()
print("null" if value == "" else json.dumps(value, ensure_ascii=True, separators=(",", ":")))'
}

last_header() {
  python3 -c 'import sys
path,want=sys.argv[1],sys.argv[2].lower(); blocks=[]; current=[]
for raw in open(path, "rb").read().splitlines():
    line=raw.decode("latin-1")
    if line.upper().startswith("HTTP/"):
        if current: blocks.append(current)
        current=[line]
    elif current:
        current.append(line)
if current: blocks.append(current)
value=""
for line in (blocks[-1] if blocks else []):
    if ":" in line:
        key,val=line.split(":",1)
        if key.lower()==want: value=val.strip()
print(value)' "$1" "$2"
}

last_status() {
  python3 -c 'import sys
codes=[]
for raw in open(sys.argv[1], "rb"):
    line=raw.decode("latin-1", "replace")
    if line.upper().startswith("HTTP/"): codes.append(line.split()[1])
if not codes: raise SystemExit("missing HTTP status")
print(codes[-1])' "$1"
}

lower_contains_header() {
  values=$1 wanted=$2
  python3 -c 'import sys
values=[v.strip().lower() for v in sys.argv[1].split(",")]
raise SystemExit(0 if sys.argv[2].lower() in values else 1)' "$values" "$wanted"
}

observe() {
  name=$1 expected=$2 service_error=$3 method=$4 path=$5 token=${6:-} body=${7:-}
  headers=$work/$name.headers
  response=$work/$name.body
  set -- curl --cacert "$ca" --http2 -sS -X "$method" -D "$headers" -o "$response" \
    -H "Origin: $origin" -H 'Accept: application/json'
  if [ -n "$token" ]; then
    printf 'Authorization: Bearer %s\n' "$token" >"$work/$name.auth"
    set -- "$@" -H "@$work/$name.auth"
  fi
  if [ -n "$body" ]; then
    printf '%s' "$body" >"$work/$name.request.json"
    set -- "$@" -H 'Content-Type: application/json' --data-binary "@$work/$name.request.json"
  fi
  "$@" "$base$path"

  actual=$(last_status "$headers")
  content_type=$(last_header "$headers" content-type)
  grpc_status=$(last_header "$headers" grpc-status)
  grpc_message=$(last_header "$headers" grpc-message)
  error_code=$(last_header "$headers" x-error-code)
  exposed=$(last_header "$headers" access-control-expose-headers)
  allow_origin=$(last_header "$headers" access-control-allow-origin)
  bytes=$(wc -c <"$response" | tr -d ' ')
  sha=$(sha256sum "$response" | cut -d' ' -f1)
  if body_json=$(json_string <"$response" 2>/dev/null); then
    body_encoding=json-string
    body_value=$body_json
  else
    body_encoding=base64
    body_value=$(openssl base64 -A <"$response" | yaml_string)
  fi
  grpc_status_value=$(printf '%s' "$grpc_status" | yaml_string)
  grpc_message_value=$(printf '%s' "$grpc_message" | yaml_string)
  error_code_value=$(printf '%s' "$error_code" | yaml_string)
  content_type_value=$(printf '%s' "$content_type" | yaml_string)
  exposed_value=$(printf '%s' "$exposed" | yaml_string)
  allow_origin_value=$(printf '%s' "$allow_origin" | yaml_string)
  path_value=$(printf '%s' "$path" | yaml_string)
  [ -n "$grpc_status" ] && grpc_status_location=response-headers-or-curl-merged-trailers || grpc_status_location=absent
  [ -n "$grpc_message" ] && grpc_message_location=response-headers-or-curl-merged-trailers || grpc_message_location=absent
  [ -n "$error_code" ] && error_code_location=response-headers-or-curl-merged-trailers || error_code_location=absent
  internal_exception_text=false
  if grep -aEqi 'exception|stack[[:space:]_-]*trace|java\.|org\.springframework|caused by:' "$response"; then
    internal_exception_text=true
  fi
  cors_x_error=false
  if [ -n "$error_code" ] && [ "$allow_origin" = "$origin" ] && lower_contains_header "$exposed" x-error-code; then
    cors_x_error=true
  fi
  cors_status_body=false
  if [ "$allow_origin" = "$origin" ]; then
    cors_status_body=true
  fi

  cat >>"$out" <<EOF
  - case: $name
    request: {method: $method, path: $path_value}
    expected_http_status: $expected
    http_status: $actual
    content_type: $content_type_value
    body:
      encoding: $body_encoding
      value: $body_value
      bytes: $bytes
      sha256: $sha
    grpc_status: {value: $grpc_status_value, location: $grpc_status_location}
    grpc_message: {value: $grpc_message_value, location: $grpc_message_location}
    x_error_code: {value: $error_code_value, location: $error_code_location}
    cors:
      allow_origin: $allow_origin_value
      expose_headers: $exposed_value
      status_and_body_browser_readable: $cors_status_body
      x_error_code_browser_readable: $cors_x_error
    contains_internal_exception_text: $internal_exception_text
EOF

  if [ "$actual" != "$expected" ]; then
    fail "$name-status-mismatch"
  fi
  if [ "$cors_status_body" != true ]; then
    fail "$name-status-body-not-browser-readable"
  fi
  if [ "$service_error" = true ]; then
    if [ -z "$error_code" ]; then
      fail "$name-x-error-code-not-promoted"
    fi
    if [ "$cors_x_error" != true ]; then
      fail "$name-x-error-code-not-browser-readable"
    fi
  fi
}

fail() {
  reason=$1
  cat >>"$out" <<EOF
gate:
  result: failed
  reason: $reason
  fallback: generated-go-grpc-gateway
release_ready: false
EOF
  printf 'G9 compatibility gate failed: %s\n' "$reason" >&2
  exit 1
}

load_setup() {
  [ -r "$status_file" ] || fail "setup-input-missing-$status_file"
  # Explicit shell assignments produced by the business fixture. No values are guessed here.
  # Required: G9_CUSTOMER_TOKEN, G9_FOREIGN_MEMBER_ID, G9_GYM_ID, G9_CONFLICT_EMAIL.
  set -a
  # shellcheck disable=SC1090
  . "$status_file"
  set +a
  : "${G9_CUSTOMER_TOKEN:?G9_CUSTOMER_TOKEN missing from $status_file}"
  : "${G9_FOREIGN_MEMBER_ID:?G9_FOREIGN_MEMBER_ID missing from $status_file}"
  : "${G9_GYM_ID:?G9_GYM_ID missing from $status_file}"
  : "${G9_CONFLICT_EMAIL:?G9_CONFLICT_EMAIL missing from $status_file}"
}


cat >"$out" <<'EOF'
# Sanitized byte-exact observations from the real Kong 3.8 fixture.
kong:
  version: 3.8
measurement:
  status: measured-stage-3
  curl_metadata_limit: response headers and HTTP/2 trailers share curl's -D stream; values are reported as merged when curl cannot distinguish them
  cases:
EOF

# Gateway-owned deterministic failures require no business data.
observe route_not_found 404 false GET /api/v1/not-a-route '' ''
observe jwt_missing 401 false GET /api/v1/users/me '' ''
observe jwt_invalid_role 403 false GET /api/v1/users/me "$invalid_role_token" ''
observe identifier_validation 400 false POST /api/v1/auth/login '' '{}'

load_setup
# Real Member/Plans transcoding failures: invalid JSON/bindings and service errors.
observe plans_transcoding_invalid_json 400 false POST /api/v1/gyms "$super_admin_token" '{'
observe plans_validation 400 true POST /api/v1/gyms "$super_admin_token" '{}'
observe member_transcoding_invalid_json 400 false PUT "/api/v1/members/$G9_FOREIGN_MEMBER_ID" "$G9_CUSTOMER_TOKEN" '{'
observe member_transcoding_invalid_query 400 false GET "/api/v1/gyms/$G9_GYM_ID/members?page=not-an-integer" "$G9_CUSTOMER_TOKEN" ''
observe member_forbidden 403 true GET "/api/v1/members/$G9_FOREIGN_MEMBER_ID" "$G9_CUSTOMER_TOKEN" ''
observe plans_not_found 404 true GET /api/v1/plans/g9-compat-missing-plan "$G9_CUSTOMER_TOKEN" ''
observe identifier_conflict 409 false POST /api/v1/auth/register '' "{\"email\":\"$G9_CONFLICT_EMAIL\",\"password\":\"G9RunnerPass1\",\"full_name\":\"G9 Compatibility\"}"

$compose exec -T plans-postgres psql -U postgres -d plans_db -c 'ALTER DATABASE plans_db SET default_transaction_read_only = on' >/dev/null
plans_database_read_only=true
$compose restart ms-gym-plans >/dev/null
for _ in $(seq 1 30); do
  if $compose exec -T ms-gym-plans bash -c "exec 3<>/dev/tcp/127.0.0.1/8080 && printf 'GET /actuator/health HTTP/1.0\\r\\n\\r\\n' >&3 && grep -q '200' <&3" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
observe service_500 500 true POST /api/v1/gyms "$super_admin_token" '{"chainId":"g9-fault","name":"g9-fault","address":"g9-fault","city":"g9-fault"}'
$compose exec -T plans-postgres psql -U postgres -d postgres -c 'ALTER DATABASE plans_db RESET default_transaction_read_only' >/dev/null
plans_database_read_only=false
$compose restart ms-gym-plans >/dev/null

$compose stop ms-gym-plans >/dev/null
plans_stopped=true
observe service_503 503 false GET /api/v1/plans/g9-compat-missing-plan "$G9_CUSTOMER_TOKEN"
$compose start ms-gym-plans >/dev/null
plans_stopped=false

python3 - "$out" <<'PY'
import sys
import yaml

cases = {item["case"]: item for item in yaml.safe_load(open(sys.argv[1]))["measurement"]["cases"]}
for name, status, body in (
    ("service_500", 500, '{"code":13, "message":"Internal server error", "details":[]}'),
    ("service_503", 503, '{"code":14, "message":"Upstream service unavailable", "details":[]}'),
):
    case = cases[name]
    if case["http_status"] != status or case["body"]["value"] != body:
        raise SystemExit(f"{name} response is not browser-safe")
PY

if grep -aEqi 'exception|stack[[:space:]_-]*trace|java\.|org\.springframework|caused by:' "$work"/*.body; then
  fail internal-exception-text-observed
fi
cat >>"$out" <<'EOF'
gate:
  result: passed
release_ready: false
EOF
printf '%s\n' 'G9 Kong 3.8 compatibility measurement passed.'

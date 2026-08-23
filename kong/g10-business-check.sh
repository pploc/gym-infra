#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
base=${G10_BASE_URL:-https://localhost:8443}
ca=${G10_CA_CERT:-$root/g10-certs/g10-ca.crt}
lock=$root/g10-release-lock.json
compose="docker compose -f $root/g10-compose.yml"
private=$root/g10-private
email="g10-$(date +%s)@example.test"
password='G10RunnerPass1'
capture_container=
skip_fixture=${G10_SKIP_FIXTURE:-0}

umask 077
rm -rf "$private"
mkdir -p "$private"

cleanup() {
  result=$?
  rm -rf "$private"
  if [ -n "$capture_container" ]; then
    docker rm -f "$capture_container" >/dev/null 2>&1 || true
  fi
  exit "$result"
}
trap cleanup EXIT INT TERM

json_field() {
  python3 -c 'import json,sys
obj=json.load(sys.stdin)
for key in sys.argv[1].split("."):
    obj=obj[int(key)] if isinstance(obj,list) else obj[key]
if obj is None: raise SystemExit("null field: "+sys.argv[1])
print(str(obj).lower() if isinstance(obj, bool) else obj)' "$1"
}

assert_json() {
  expression=$1
  shift
  python3 -c 'import json,sys
obj=json.load(sys.stdin)
globals={"__builtins__": {"any":any,"isinstance":isinstance,"len":len,"int":int,"str":str,"list":list,"dict":dict}, "obj":obj, "args":sys.argv[2:]}
assert eval(sys.argv[1], globals), obj' "$expression" "$@"
}

request() {
  name=$1 method=$2 path=$3 token=${4:-} body=${5:-}
  headers=$private/$name.headers
  output=$private/$name.body
  set -- curl --cacert "$ca" -sS -X "$method" -D "$headers" -o "$output" -H 'Accept: application/json'
  if [ -n "$token" ]; then
    printf 'Authorization: Bearer %s\n' "$token" >"$private/$name.auth"
    set -- "$@" -H "@$private/$name.auth"
  fi
  if [ -n "$body" ]; then
    printf '%s' "$body" >"$private/$name.json"
    set -- "$@" -H 'Content-Type: application/json' --data-binary "@$private/$name.json"
  fi
  "$@" "$base$path"
  python3 -c 'import sys
codes=[line.split()[1] for line in open(sys.argv[1],errors="replace") if line.upper().startswith("HTTP/")]
assert codes
print(codes[-1])' "$headers"
}

expect_status() {
  expected=$1 name=$2 method=$3 path=$4
  shift 4
  actual=$(request "$name" "$method" "$path" "$@")
  [ "$actual" = "$expected" ] || {
    printf 'expected HTTP %s, got %s for %s %s\n' "$expected" "$actual" "$method" "$path" >&2
    return 1
  }
}

body() { cat "$private/$1.body"; }

sql_identity() { $compose exec -T identity-postgres psql -U postgres -d identity_db -tA -c "$1"; }
sql_member() { $compose exec -T member-postgres psql -U postgres -d gym_member -tA -c "$1"; }

wait_for() {
  name=$1 command=$2
  for _ in $(seq 1 120); do
    if sh -c "$command" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  printf '%s\n' "Timed out waiting for $name." >&2
  return 1
}

run_case() {
  name=$1 expected=$2 method=$3 path=$4
  actual=$(curl --cacert "$ca" -sS -o /dev/null -w '%{http_code}' -X "$method" "$base$path" || true)
  [ "$actual" = "$expected" ] || status=1
  printf '%s\t%s\t%s\n' "$name" "$actual" "$([ "$actual" = "$expected" ] && printf passed || printf failed)" >&2
}

status=0
checks=''

add_check() {
  name=$1 result=$2 code=$3
  checks="$checks$(printf '\n%s\t%s\t%s' "$name" "$result" "$code")"
}

# Shared route/auth negatives.
run_case health 404 GET /status
run_case unknown_route 404 GET /api/v1/not-a-route
run_case missing_jwt_identity 401 GET /api/v1/users/me
run_case missing_jwt_checkins_me 401 GET /api/v1/check-ins/me
run_case missing_jwt_display_qr 401 GET /api/v1/gyms/00000000-0000-0000-0000-000000000001/check-in-qr
run_case direct_grpc_path 404 POST /checkin.v1.CheckInService/ProcessScan
run_case trailing_slash 404 GET /api/v1/users/me/
if [ "$status" -eq 0 ]; then
  add_check route_and_auth_negative_matrix passed 0
else
  add_check route_and_auth_negative_matrix failed "$status"
fi

if [ "$skip_fixture" != 1 ]; then
  printf '%s\n' 'G10 phase: check-in fixture setup' >&2
  capture_container=g10-token-capture
  $compose run -d --name "$capture_container" --no-deps schema-seed sh -ec '
    work=$(mktemp -d) && cp -a /source/. "$work/" && cd "$work" &&
    ./gradlew captureEmailVerificationToken -PkafkaBrokers=kafka:29092 -PschemaRegistryUrl=http://schema-registry:8081 -Pemail="$1" -PtimeoutSeconds=120 -PoutputPath=/tmp/verification-token --no-daemon 1>&2
  ' sh "$email" >/dev/null

  expect_status 200 register POST /api/v1/auth/register '' "{\"email\":\"$email\",\"password\":\"$password\",\"full_name\":\"G10 Customer\"}"
  wait_for 'registered Identity row' "$compose exec -T identity-postgres psql -U postgres -d identity_db -tAc \"SELECT 1 FROM users WHERE email='$email' AND status='PENDING_VERIFICATION'\" | grep -qx 1"
  user_id=$(sql_identity "SELECT id FROM users WHERE email='$email'")
  wait_for 'Member shell projection' "$compose exec -T member-postgres psql -U postgres -d gym_member -tAc \"SELECT 1 FROM members WHERE user_id='$user_id'\" | grep -qx 1"

  wait_for 'verification token capture' "docker inspect -f '{{.State.Running}}' '$capture_container' 2>/dev/null | grep -qx false"
  [ "$(docker inspect -f '{{.State.ExitCode}}' "$capture_container")" = 0 ]
  verification_token=$(docker cp "$capture_container:/tmp/verification-token" - | tar -xO)
  [ -n "$verification_token" ]
  docker rm "$capture_container" >/dev/null
  capture_container=

  expect_status 200 verify POST /api/v1/auth/email/verify '' "{\"verification_token\":\"$verification_token\"}"
  expect_status 200 login POST /api/v1/auth/login '' "{\"email\":\"$email\",\"password\":\"$password\"}"
  customer=$(body login | json_field access_token)

  expect_status 200 history-me GET /api/v1/check-ins/me "$customer"
  body history-me | assert_json 'obj["total"] == 0 and obj["records"] == []'
  add_check checkin_my_history_positive passed 0
  printf '%s\n' 'checkin_my_history_positive passed' >&2

  sql_identity "UPDATE users SET role='SUPER_ADMIN' WHERE id='$user_id'" >/dev/null
  expect_status 200 admin-login POST /api/v1/auth/login '' "{\"email\":\"$email\",\"password\":\"$password\"}"
  admin=$(body admin-login | json_field access_token)

  expect_status 200 gym-create POST /api/v1/gyms "$admin" '{"chainId":"chain-g10","name":"G10 Downtown","address":"10 Gateway Way","city":"Map City"}'
  gym_id=$(body gym-create | json_field id)

  expect_status 200 display-qr GET "/api/v1/gyms/$gym_id/check-in-qr" "$admin"
  body display-qr | assert_json 'obj["gymId"] == args[0] and isinstance(obj["slotDurationSeconds"], int) and obj["slotDurationSeconds"] > 0 and isinstance(obj["current"]["qrPayload"], str) and len(obj["current"]["qrPayload"]) > 0 and isinstance(obj["next"]["qrPayload"], str) and len(obj["next"]["qrPayload"]) > 0' "$gym_id"
  add_check checkin_display_qr_positive passed 0
  printf '%s\n' 'checkin_display_qr_positive passed' >&2

  expect_status 403 display-qr-customer GET "/api/v1/gyms/$gym_id/check-in-qr" "$customer"
  add_check checkin_display_qr_customer_forbidden passed 0
  printf '%s\n' 'checkin_display_qr_customer_forbidden passed' >&2

  qr=$(body display-qr | json_field current.qrPayload)
  member_id=$(sql_member "SELECT id FROM members WHERE user_id='$user_id'")
  [ -n "$member_id" ]
  [ -n "$qr" ]

  # No ACTIVE subscription yet: scan must fail closed.
  expect_status 409 scan-inactive POST /api/v1/check-ins:scan "$customer" "{\"gymId\":\"$gym_id\",\"qrPayload\":\"$qr\",\"idempotencyKey\":\"g10-inactive-$user_id\"}"
  add_check checkin_scan_membership_inactive passed 0
  printf '%s\n' 'checkin_scan_membership_inactive passed' >&2

  sql_member "INSERT INTO subscriptions (id, member_id, gym_id, plan_id, plan_type_snapshot, duration_days_snapshot, price_vnd_snapshot, status, start_date, end_date, pause_count) VALUES (gen_random_uuid()::text, '$member_id', '$gym_id', 'plan-g10-fixture', 'MONTHLY', 30, 450000, 'ACTIVE', CURRENT_DATE, CURRENT_DATE + 30, 0)" >/dev/null
  wait_for 'ACTIVE subscription' "$compose exec -T member-postgres psql -U postgres -d gym_member -tAc \"SELECT status FROM subscriptions WHERE member_id='$member_id' AND gym_id='$gym_id'\" | grep -qx ACTIVE"

  expect_status 200 scan-positive POST /api/v1/check-ins:scan "$customer" "{\"gymId\":\"$gym_id\",\"qrPayload\":\"$qr\",\"idempotencyKey\":\"g10-scan-$user_id\"}"
  body scan-positive | assert_json 'obj["success"] is True and obj["record"]["gymId"] == args[0] and obj["record"]["memberId"] == args[1] and isinstance(obj["record"]["id"], str) and len(obj["record"]["id"]) > 0' "$gym_id" "$member_id"
  record_id=$(body scan-positive | json_field record.id)
  add_check checkin_scan_positive passed 0
  printf '%s\n' 'checkin_scan_positive passed' >&2

  expect_status 200 scan-replay POST /api/v1/check-ins:scan "$customer" "{\"gymId\":\"$gym_id\",\"qrPayload\":\"$qr\",\"idempotencyKey\":\"g10-scan-$user_id\"}"
  body scan-replay | assert_json 'obj["success"] is True and obj["record"]["id"] == args[0]' "$record_id"
  add_check checkin_scan_idempotent_replay passed 0
  printf '%s\n' 'checkin_scan_idempotent_replay passed' >&2

  expect_status 409 scan-conflict POST /api/v1/check-ins:scan "$customer" "{\"gymId\":\"$gym_id\",\"qrPayload\":\"$qr-tampered\",\"idempotencyKey\":\"g10-scan-$user_id\"}"
  add_check checkin_scan_idempotency_conflict passed 0
  printf '%s\n' 'checkin_scan_idempotency_conflict passed' >&2

  expect_status 200 history-after GET /api/v1/check-ins/me "$customer"
  body history-after | assert_json 'obj["total"] == 1 and len(obj["records"]) == 1 and obj["records"][0]["id"] == args[0]' "$record_id"
  add_check checkin_my_history_after_scan passed 0
  printf '%s\n' 'checkin_my_history_after_scan passed' >&2
fi

python3 - "$lock" "$status" "$checks" <<'PY'
import json, sys
from pathlib import Path
import yaml

lock = json.loads(Path(sys.argv[1]).read_text())
status = int(sys.argv[2])
checks = []
for line in sys.argv[3].splitlines():
    if not line.strip():
        continue
    name, result, code = line.split("\t")
    checks.append({"name": name, "result": result, "exitCode": int(code)})
    if result != "passed" or int(code) != 0:
        status = 1

evidence = {
    "schemaVersion": 1,
    "lock": {
        "sourceShas": {name: item["sha"] for name, item in lock["repositories"].items()},
        "imageDigests": lock["images"],
        "checksums": lock["checksums"],
    },
    "gates": {"result": "passed" if status == 0 else "failed", "exitCodes": {"business": status}},
    "checks": checks,
}
sys.stdout.write(yaml.safe_dump(evidence, sort_keys=False))
raise SystemExit(status)
PY
printf '%s\n' 'G10 business matrix passed.' >&2

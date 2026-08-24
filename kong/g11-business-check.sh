#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
base=${G11_BASE_URL:-https://localhost:8443}
ca=${G11_CA_CERT:-$root/g11-certs/g11-ca.crt}
compose="docker compose -f $root/g11-compose.yml"
secret=${G11_SEPAY_WEBHOOK_SECRET:?G11_SEPAY_WEBHOOK_SECRET is required}
account=${G11_SEPAY_ACCOUNT_NUMBER:-g11-account}
private=$root/g11-private
email="g11-$(date +%s)@example.test"
password='G11RunnerPass1'
capture_container=

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

sql_identity() { $compose exec -T identity-postgres psql -U postgres -d identity_db -tA -c "$1"; }
sql_member() { $compose exec -T member-postgres psql -U postgres -d gym_member -tA -c "$1"; }
sql_payment() { $compose exec -T payment-postgres psql -U postgres -d payment_db -tA -c "$1"; }

wait_for() {
  name=$1 command=$2
  for _ in $(seq 1 120); do
    if sh -c "$command" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  printf 'Timed out waiting for %s.\n' "$name" >&2
  return 1
}

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

# Given a fresh customer, when verified through Identifier, then Member projects a shell.
capture_container=g11-token-capture
$compose run -d --name "$capture_container" --no-deps schema-seed sh -ec '
  work=$(mktemp -d) && cp -a /source/. "$work/" && cd "$work" &&
  exec ./gradlew captureEmailVerificationToken -PkafkaBrokers=kafka:29092 -PschemaRegistryUrl=http://schema-registry:8081 -Pemail="$1" -PtimeoutSeconds=120 -PoutputPath=/tmp/verification-token --no-daemon 1>&2
' sh "$email" >/dev/null

expect_status 200 register POST /api/v1/auth/register '' "{\"email\":\"$email\",\"password\":\"$password\",\"full_name\":\"G11 Customer\"}"
wait_for 'registered Identity row' "$compose exec -T identity-postgres psql -U postgres -d identity_db -tAc \"SELECT 1 FROM users WHERE email='$email' AND status='PENDING_VERIFICATION'\" | grep -qx 1"
user_id=$(sql_identity "SELECT id FROM users WHERE email='$email'")
wait_for 'Member shell projection' "$compose exec -T member-postgres psql -U postgres -d gym_member -tAc \"SELECT 1 FROM members WHERE user_id='$user_id'\" | grep -qx 1"
member_id=$(sql_member "SELECT id FROM members WHERE user_id='$user_id'")

wait_for 'verification token capture' "docker inspect -f '{{.State.Running}}' '$capture_container' 2>/dev/null | grep -qx false"
[ "$(docker inspect -f '{{.State.ExitCode}}' "$capture_container")" = 0 ]
verification_token=$(docker cp "$capture_container:/tmp/verification-token" - | tar -xO)
[ -n "$verification_token" ]
docker rm "$capture_container" >/dev/null
capture_container=
expect_status 200 verify POST /api/v1/auth/email/verify '' "{\"verification_token\":\"$verification_token\"}"
expect_status 200 customer-login POST /api/v1/auth/login '' "{\"email\":\"$email\",\"password\":\"$password\"}"
customer=$(body customer-login | json_field access_token)

# Given an administrator catalog, when a customer buys an active plan, then Payment owns one SEPAY intent.
sql_identity "UPDATE users SET role='SUPER_ADMIN' WHERE id='$user_id'" >/dev/null
expect_status 200 admin-login POST /api/v1/auth/login '' "{\"email\":\"$email\",\"password\":\"$password\"}"
admin=$(body admin-login | json_field access_token)
expect_status 200 gym-create POST /api/v1/gyms "$admin" '{"chainId":"chain-g11","name":"G11 Downtown","address":"11 Gateway Way","city":"Map City"}'
gym_id=$(body gym-create | json_field id)
expect_status 200 plan-create POST "/api/v1/gyms/$gym_id/plans" "$admin" '{"name":"G11 Monthly","planType":"PLAN_TYPE_MONTHLY","durationDays":30,"priceVnd":"450000","description":"locked payment fixture","active":true}'
plan_id=$(body plan-create | json_field id)

sql_identity "UPDATE users SET role='CUSTOMER' WHERE id='$user_id'" >/dev/null
expect_status 200 customer-relogin POST /api/v1/auth/login '' "{\"email\":\"$email\",\"password\":\"$password\"}"
customer=$(body customer-relogin | json_field access_token)
idempotency_key="g11-$user_id-$plan_id"
purchase_body="{\"planId\":\"$plan_id\",\"provider\":\"SEPAY\",\"discountCode\":\"\",\"idempotencyKey\":\"$idempotency_key\"}"
expect_status 200 purchase POST "/api/v1/gyms/$gym_id/memberships/purchase" "$customer" "$purchase_body"
payment_id=$(body purchase | json_field paymentId)
payment_url=$(body purchase | json_field paymentUrl)
[ -n "$payment_id" ]
[ -n "$payment_url" ]
expect_status 200 purchase-replay POST "/api/v1/gyms/$gym_id/memberships/purchase" "$customer" "$purchase_body"
body purchase-replay | assert_json 'obj["paymentId"] == args[0] and obj["paymentUrl"] == args[1]' "$payment_id" "$payment_url"

purchase=$(sql_member "SELECT id FROM pending_purchases WHERE payment_id='$payment_id'")
reference=$(sql_payment "SELECT payment_code FROM payment_intents WHERE id='$payment_id'")
amount=$(sql_payment "SELECT intent_amount_vnd FROM payment_intents WHERE id='$payment_id'")
[ -n "$purchase" ]
[ -n "$reference" ]
[ "$amount" = 450000 ]
received=$((amount + 1))

# Given a verified overpayment, when exact callback replays, then one frozen completion activates Member once.
callback_body=$(printf '{"id":11001,"accountNumber":"%s","code":"%s","transferType":"in","transferAmount":%s,"content":"G11 membership overpay","referenceCode":"g11-callback-overpay"}' "$account" "$reference" "$received")
timestamp=$(date +%s)
signature=$(python3 - "$secret" "$timestamp" "$callback_body" <<'PY'
import hashlib,hmac,sys
print("sha256=" + hmac.new(sys.argv[1].encode(), f"{sys.argv[2]}.{sys.argv[3]}".encode(), hashlib.sha256).hexdigest())
PY
)
post() {
  printf '%s' "$callback_body" | curl --cacert "$ca" -fsS -X POST \
    -H 'Content-Type: application/json' \
    -H "X-SePay-Timestamp: $timestamp" \
    -H "X-SePay-Signature: $signature" \
    --data-binary @- "$base/api/v1/payments/webhook/sepay"
}
post >/dev/null
post >/dev/null
[ "$(sql_payment "SELECT intent_amount_vnd FROM payment_intents WHERE payment_code='$reference'" | tr -d '[:space:]')" = "$amount" ]
[ "$(sql_payment "SELECT received_amount_vnd FROM payment_intents WHERE payment_code='$reference'" | tr -d '[:space:]')" = "$received" ]
[ "$(sql_payment "SELECT count(*) FROM outbox_events WHERE dedupe_key = 'payment.completed.v1:' || (SELECT id FROM payment_intents WHERE payment_code='$reference')" | tr -d '[:space:]')" = 1 ]

for _ in $(seq 1 120); do
  state=$(sql_member "SELECT status FROM pending_purchases WHERE id='$purchase'" | tr -d '[:space:]')
  count=$(sql_member "SELECT count(*) FROM subscriptions s JOIN pending_purchases p ON p.member_id=s.member_id AND p.gym_id=s.gym_id WHERE p.id='$purchase' AND s.status='ACTIVE'" | tr -d '[:space:]')
  [ "$state" = COMPLETED ] && [ "$count" = 1 ] && {
    python3 - <<'PY'
import yaml
print(yaml.safe_dump({
    "schemaVersion": 1,
    "mode": "image-lock-pending-gate",
    "gates": {"result": "passed", "exitCodes": {"business": 0}},
    "checks": [
        {"name": "membership_sepay_initiation_idempotency", "result": "passed", "exitCode": 0},
        {"name": "sepay_hmac_overpayment_replay", "result": "passed", "exitCode": 0},
        {"name": "member_activation_once", "result": "passed", "exitCode": 0},
        {"name": "payment_outbox_single_completion", "result": "passed", "exitCode": 0},
    ],
}, sort_keys=False), end="")
PY
    exit 0
  }
  sleep 1
done
printf '%s\n' 'G11 Member activation did not complete.' >&2
exit 1

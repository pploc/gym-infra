#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
compose="docker compose -f $root/g8-compose.yml"
private_dir=$root/g8-private
email="g8-$(date +%s)@example.test"
password='G8RunnerPass1'
header_file=$private_dir/authorization-header
status_file=$root/g8-business-status
capture_container=
step=initializing
network=gym-g8_default

umask 077
mkdir -p "$private_dir"
printf '%s\n' "running: $step" >"$status_file"
cleanup() {
  status=$?
  rm -rf "$private_dir"
  if [ -n "$capture_container" ]; then
    docker rm -f "$capture_container" >/dev/null 2>&1 || true
  fi
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "failed: $step" >"$status_file"
    printf '%s\n' "G8 business check failed at: $step" >&2
  else
    rm -f "$status_file"
  fi
}
trap cleanup EXIT INT TERM

sql_identity() {
  $compose exec -T identity-postgres psql -U postgres -d identity_db -tA -c "$1"
}

sql_member() {
  $compose exec -T member-postgres psql -U postgres -d gym_member -tA -c "$1"
}

sql_plans() {
  $compose exec -T plans-postgres psql -U postgres -d plans_db -tA -c "$1"
}

wait_for() {
  name=$1
  command=$2
  for _ in $(seq 1 120); do
    if sh -c "$command" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  printf '%s\n' "Timed out waiting for $name." >&2
  return 1
}

json_field() {
  field=$1
  python3 -c 'import json, sys
obj = json.load(sys.stdin)
key = sys.argv[1]
if key not in obj or obj[key] is None:
  raise SystemExit(f"missing field {key}: {obj!r}")
value = obj[key]
print(value)' "$field"
}

assert_neutral_token() {
  python3 -c 'import base64, json, sys
p = sys.stdin.read().strip().split(".")
assert len(p) == 3
claims = json.loads(base64.urlsafe_b64decode(p[1] + "=" * (-len(p[1]) % 4)))
assert claims.get("membership_status") == "NONE"
assert "gym_id" not in claims or claims.get("gym_id") in ("", None)
assert isinstance(claims.get("iat"), (int, float))
assert isinstance(claims.get("jti"), str) and claims["jti"]
assert claims.get("iss") == "gym-identifier"
assert claims.get("aud") == "gym-api"'
}

assert_selected_token() {
  expected_gym=$1
  expected_status=$2
  python3 -c 'import base64, json, sys
p = sys.stdin.read().strip().split(".")
assert len(p) == 3
claims = json.loads(base64.urlsafe_b64decode(p[1] + "=" * (-len(p[1]) % 4)))
assert claims.get("gym_id") == sys.argv[1]
assert claims.get("membership_status") == sys.argv[2]
assert isinstance(claims.get("iat"), (int, float))
assert isinstance(claims.get("jti"), str) and claims["jti"]' "$expected_gym" "$expected_status"
}

post_json() {
  path=$1
  body=$2
  printf '%s' "$body" | curl -fsS -H 'Content-Type: application/json' --data-binary @- "http://localhost:8000$path"
}

authorized_json() {
  method=$1
  path=$2
  body=$3
  token=$4
  printf 'Authorization: Bearer %s\n' "$token" >"$header_file"
  printf '%s' "$body" | curl -fsS -X "$method" -H 'Content-Type: application/json' -H "@$header_file" --data-binary @- "http://localhost:8000$path"
  rm -f "$header_file"
}

authorized_status_body() {
  path=$1
  token=$2
  method=$3
  body=$4
  printf 'Authorization: Bearer %s\n' "$token" >"$header_file"
  printf '%s' "$body" | curl -sS -o /dev/null -w '%{http_code}' -X "$method" -H 'Content-Type: application/json' -H "@$header_file" --data-binary @- "http://localhost:8000$path"
  rm -f "$header_file"
}

grpcurl_member_purchase() {
  plan_id=$1
  provider=$2
  user_id=$3
  gym_id=$4
  membership=$5
  idempotency_key=$6
  # End-user RPCs require Kong SAN; claims are accepted only from that peer.
  docker run --rm --network "$network" \
    -v "$root/g8-certs:/certs:ro" \
    --user "$(id -u):$(id -g)" \
    fullstorydev/grpcurl:v1.9.1 \
    -cacert /certs/ca.crt \
    -cert /certs/kong.crt \
    -key /certs/kong.key \
    -servername ms-gym-member \
    -H "x-user-id: $user_id" \
    -H "x-user-role: CUSTOMER" \
    -H "x-gym-id: $gym_id" \
    -H "x-membership-status: $membership" \
    -d "{\"planId\":\"$plan_id\",\"provider\":\"$provider\",\"idempotencyKey\":\"$idempotency_key\"}" \
    ms-gym-member:50051 member.v1.MemberService/PurchaseMembership
}

grpcurl_plans_resolve_as_identifier() {
  plan_id=$1
  gym_id=$2
  # Identifier peer must be denied ResolvePurchasablePlan.
  set +e
  out=$(docker run --rm --network "$network" \
    -v "$root/g8-certs:/certs:ro" \
    --user "$(id -u):$(id -g)" \
    fullstorydev/grpcurl:v1.9.1 \
    -cacert /certs/ca.crt \
    -cert /certs/identifier.crt \
    -key /certs/identifier.key \
    -servername ms-gym-plans \
    -d "{\"planId\":\"$plan_id\",\"gymId\":\"$gym_id\"}" \
    ms-gym-plans:50051 plans.v1.PlansService/ResolvePurchasablePlan 2>&1)
  code=$?
  set -e
  [ "$code" -ne 0 ]
  printf '%s' "$out" | grep -Eqi 'PermissionDenied|PERMISSION_DENIED|permission denied'
}

grpcurl_plans_active_as_member() {
  gym_id=$1
  set +e
  out=$(docker run --rm --network "$network" \
    -v "$root/g8-certs:/certs:ro" \
    --user "$(id -u):$(id -g)" \
    fullstorydev/grpcurl:v1.9.1 \
    -cacert /certs/ca.crt \
    -cert /certs/member-client.crt \
    -key /certs/member-client.key \
    -servername ms-gym-plans \
    -d "{\"gymId\":\"$gym_id\"}" \
    ms-gym-plans:50051 plans.v1.PlansService/GetActiveGym 2>&1)
  code=$?
  set -e
  [ "$code" -ne 0 ]
  printf '%s' "$out" | grep -Eqi 'PermissionDenied|PERMISSION_DENIED|permission denied'
}

capture_container=g8-token-capture
step='starting verification capture'
printf '%s\n' "running: $step" >"$status_file"
$compose run -d --name "$capture_container" --no-deps schema-seed sh -ec '
  cp -R /source/. /tmp/gym-proto &&
  cd /tmp/gym-proto &&
  ./gradlew captureEmailVerificationToken -PkafkaBrokers=kafka:29092 -PschemaRegistryUrl=http://schema-registry:8081 -Pemail="$1" -PtimeoutSeconds=120 -PoutputPath=/tmp/verification-token --no-daemon 1>&2
' sh "$email" >/dev/null

step='registering customer'
printf '%s\n' "running: $step" >"$status_file"
register_response=$(post_json /api/v1/auth/register "{\"email\":\"$email\",\"password\":\"$password\",\"full_name\":\"G8 Runner\"}")
[ "$(printf '%s' "$register_response" | json_field status)" = 'USER_STATUS_PENDING_VERIFICATION' ]

step='checking registration transaction'
printf '%s\n' "running: $step" >"$status_file"
wait_for 'registration transaction' "$compose exec -T identity-postgres psql -U postgres -d identity_db -tAc \"SELECT 1 FROM users WHERE email = '$email' AND status = 'PENDING_VERIFICATION' AND email_verified = false\" | grep -qx 1"
user_id=$(sql_identity "SELECT id FROM users WHERE email = '$email'")
[ -n "$user_id" ]

step='waiting for registration outbox publication'
printf '%s\n' "running: $step" >"$status_file"
wait_for 'registration outbox publication' "$compose exec -T identity-postgres psql -U postgres -d identity_db -tAc \"SELECT count(*) FROM outbox_events WHERE key = '$user_id' AND status = 'PUBLISHED'\" | grep -Eq '^[2-9]$|^[1-9][0-9]+$'"

step='waiting for Member shell projection'
printf '%s\n' "running: $step" >"$status_file"
wait_for 'Member shell projection' "$compose exec -T member-postgres psql -U postgres -d gym_member -tAc \"SELECT count(*) FROM members WHERE user_id = '$user_id'\" | grep -qx 1"
member_id=$(sql_member "SELECT id FROM members WHERE user_id = '$user_id'")
[ -n "$member_id" ]

step='checking verification capture'
printf '%s\n' "running: $step" >"$status_file"
wait_for 'verification capture completion' "docker inspect -f '{{.State.Running}}' '$capture_container' 2>/dev/null | grep -qx false"
capture_exit=$(docker inspect -f '{{.State.ExitCode}}' "$capture_container")
[ "$capture_exit" = 0 ]
verification_token=$(docker cp "$capture_container:/tmp/verification-token" - | tar -xO)
[ -n "$verification_token" ]
docker rm "$capture_container" >/dev/null
capture_container=

step='verifying email'
printf '%s\n' "running: $step" >"$status_file"
verify_response=$(post_json /api/v1/auth/email/verify "{\"verification_token\":\"$verification_token\"}")
verify_access=$(printf '%s' "$verify_response" | json_field access_token)
printf '%s' "$verify_access" | assert_neutral_token

step='logging in customer'
printf '%s\n' "running: $step" >"$status_file"
login_response=$(post_json /api/v1/auth/login "{\"email\":\"$email\",\"password\":\"$password\"}")
login_access=$(printf '%s' "$login_response" | json_field access_token)
printf '%s' "$login_access" | assert_neutral_token

step='promoting super admin for Plans catalog'
printf '%s\n' "running: $step" >"$status_file"
sql_identity "UPDATE users SET role = 'SUPER_ADMIN' WHERE id = '$user_id'" >/dev/null
admin_login=$(post_json /api/v1/auth/login "{\"email\":\"$email\",\"password\":\"$password\"}")
admin_access=$(printf '%s' "$admin_login" | json_field access_token)

chain_id=chain-g8
step='creating active gym through Plans HTTP'
printf '%s\n' "running: $step" >"$status_file"
gym_resp=$(authorized_json POST /api/v1/gyms "{\"chainId\":\"$chain_id\",\"name\":\"G8 Active Gym\",\"address\":\"1 Test Way\",\"city\":\"Test City\"}" "$admin_access")
gym_id=$(printf '%s' "$gym_resp" | json_field id)
[ -n "$gym_id" ]
[ "$(sql_plans "SELECT status FROM gym_locations WHERE id = '$gym_id'")" = ACTIVE ]

step='creating active plan through Plans HTTP'
printf '%s\n' "running: $step" >"$status_file"
plan_resp=$(authorized_json POST "/api/v1/gyms/$gym_id/plans" "{\"name\":\"G8 Monthly\",\"planType\":\"PLAN_TYPE_MONTHLY\",\"durationDays\":30,\"priceVnd\":450000,\"description\":\"g8\",\"active\":true}" "$admin_access")
plan_id=$(printf '%s' "$plan_resp" | json_field id)
[ -n "$plan_id" ]
price=$(sql_plans "SELECT price_vnd FROM membership_plans WHERE id = '$plan_id'")
[ "$price" = 450000 ]

step='creating closed gym for negative selection'
printf '%s\n' "running: $step" >"$status_file"
closed_resp=$(authorized_json POST /api/v1/gyms "{\"chainId\":\"$chain_id\",\"name\":\"G8 Closed Gym\",\"address\":\"2 Test Way\",\"city\":\"Test City\"}" "$admin_access")
closed_gym_id=$(printf '%s' "$closed_resp" | json_field id)
authorized_json PUT "/api/v1/gyms/$closed_gym_id" "{\"chainId\":\"$chain_id\",\"name\":\"G8 Closed Gym\",\"address\":\"2 Test Way\",\"city\":\"Test City\",\"status\":\"GYM_LOCATION_STATUS_CLOSED\"}" "$admin_access" >/dev/null
[ "$(sql_plans "SELECT status FROM gym_locations WHERE id = '$closed_gym_id'")" = CLOSED ]

step='demoting back to customer for selection'
printf '%s\n' "running: $step" >"$status_file"
sql_identity "UPDATE users SET role = 'CUSTOMER' WHERE id = '$user_id'" >/dev/null
customer_login=$(post_json /api/v1/auth/login "{\"email\":\"$email\",\"password\":\"$password\"}")
customer_access=$(printf '%s' "$customer_login" | json_field access_token)

step='selecting gym with NONE membership'
printf '%s\n' "running: $step" >"$status_file"
selected_none=$(authorized_json POST /api/v1/auth/gym "{\"gym_id\":\"$gym_id\"}" "$customer_access")
[ "$(printf '%s' "$selected_none" | json_field gym_id)" = "$gym_id" ]
[ "$(printf '%s' "$selected_none" | json_field membership_status)" = 'MEMBERSHIP_STATUS_NONE' ]
selected_access=$(printf '%s' "$selected_none" | json_field access_token)
printf '%s' "$selected_access" | assert_selected_token "$gym_id" NONE

step='rejecting anonymous Plans mutation'
printf '%s\n' "running: $step" >"$status_file"
anon_code=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' --data-binary '{"chainId":"x","name":"n","address":"a","city":"c"}' http://localhost:8000/api/v1/gyms)
[ "$anon_code" = 401 ]

step='rejecting missing gym selection'
printf '%s\n' "running: $step" >"$status_file"
missing_code=$(authorized_status_body /api/v1/auth/gym "$customer_access" POST '{"gym_id":"00000000-0000-0000-0000-000000000099"}')
[ "$missing_code" -ge 400 ]

step='rejecting closed gym selection'
printf '%s\n' "running: $step" >"$status_file"
closed_code=$(authorized_status_body /api/v1/auth/gym "$customer_access" POST "{\"gym_id\":\"$closed_gym_id\"}")
[ "$closed_code" -ge 400 ]

step='schema ownership proof'
printf '%s\n' "running: $step" >"$status_file"
[ "$(sql_plans "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('gym_locations','membership_plans')")" = 2 ]
[ "$(sql_member "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('gym_locations','membership_plans')")" = 0 ]
[ "$(sql_member "SELECT count(*) FROM information_schema.columns WHERE table_name='subscriptions' AND column_name IN ('plan_type_snapshot','duration_days_snapshot','price_vnd_snapshot')")" = 3 ]
[ "$(sql_member "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='pending_purchases'")" = 1 ]
[ "$(sql_identity "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('gym_locations','membership_plans','pending_purchases')")" = 0 ]

step='denying Identifier peer on ResolvePurchasablePlan'
printf '%s\n' "running: $step" >"$status_file"
grpcurl_plans_resolve_as_identifier "$plan_id" "$gym_id"

step='denying Member peer on GetActiveGym'
printf '%s\n' "running: $step" >"$status_file"
grpcurl_plans_active_as_member "$gym_id"

step='purchasing membership over Member gRPC'
printf '%s\n' "running: $step" >"$status_file"
purchase_json=$(grpcurl_member_purchase "$plan_id" MOMO "$user_id" "$gym_id" NONE "g8-purchase-$user_id-$plan_id")
# grpcurl defaults to camelCase JSON
payment_id=$(printf '%s' "$purchase_json" | json_field paymentId)
[ -n "$payment_id" ]
purchase_id=$(sql_member "SELECT id FROM pending_purchases WHERE payment_id = '$payment_id'")
[ -n "$purchase_id" ]
[ "$(sql_member "SELECT status FROM pending_purchases WHERE id = '$purchase_id'")" = PENDING ]
[ "$(sql_member "SELECT price_vnd_snapshot FROM pending_purchases WHERE id = '$purchase_id'")" = 450000 ]

step='completing fake payment'
printf '%s\n' "running: $step" >"$status_file"
complete_json=$($compose exec -T fake-payment wget -qO- --header='Content-Type: application/json' --post-data="{\"payment_id\":\"$payment_id\"}" http://127.0.0.1:8080/complete)
event_id=$(printf '%s' "$complete_json" | json_field event_id)
[ -n "$event_id" ]

step='waiting for subscription activation'
printf '%s\n' "running: $step" >"$status_file"
wait_for 'subscription ACTIVE' "$compose exec -T member-postgres psql -U postgres -d gym_member -tAc \"SELECT status FROM subscriptions WHERE member_id = '$member_id' AND gym_id = '$gym_id'\" | grep -qx ACTIVE"
[ "$(sql_member "SELECT status FROM pending_purchases WHERE id = '$purchase_id'")" = COMPLETED ]
[ "$(sql_member "SELECT plan_type_snapshot FROM subscriptions WHERE member_id = '$member_id' AND gym_id = '$gym_id'")" = MONTHLY ]
[ "$(sql_member "SELECT price_vnd_snapshot FROM subscriptions WHERE member_id = '$member_id' AND gym_id = '$gym_id'")" = 450000 ]
[ "$(sql_member "SELECT duration_days_snapshot FROM subscriptions WHERE member_id = '$member_id' AND gym_id = '$gym_id'")" = 30 ]

step='selecting gym after activation reports ACTIVE'
printf '%s\n' "running: $step" >"$status_file"
selected_active=$(authorized_json POST /api/v1/auth/gym "{\"gym_id\":\"$gym_id\"}" "$customer_access")
[ "$(printf '%s' "$selected_active" | json_field membership_status)" = 'MEMBERSHIP_STATUS_ACTIVE' ]
printf '%s' "$selected_active" | json_field access_token | assert_selected_token "$gym_id" ACTIVE

step='replaying payment completion is idempotent'
printf '%s\n' "running: $step" >"$status_file"
$compose exec -T fake-payment wget -qO- --header='Content-Type: application/json' --post-data="{\"payment_id\":\"$payment_id\"}" http://127.0.0.1:8080/replay >/dev/null
sleep 3
[ "$(sql_member "SELECT count(*) FROM subscriptions WHERE member_id = '$member_id' AND gym_id = '$gym_id'")" = 1 ]
[ "$(sql_member "SELECT status FROM pending_purchases WHERE id = '$purchase_id'")" = COMPLETED ]

step='catalog edit after initiation does not alter frozen terms'
printf '%s\n' "running: $step" >"$status_file"
sql_identity "UPDATE users SET role = 'SUPER_ADMIN' WHERE id = '$user_id'" >/dev/null
admin2=$(post_json /api/v1/auth/login "{\"email\":\"$email\",\"password\":\"$password\"}")
admin2_access=$(printf '%s' "$admin2" | json_field access_token)
authorized_json PUT "/api/v1/plans/$plan_id" "{\"name\":\"G8 Monthly\",\"planType\":\"PLAN_TYPE_MONTHLY\",\"durationDays\":30,\"priceVnd\":999999,\"description\":\"mutated\",\"active\":true}" "$admin2_access" >/dev/null
[ "$(sql_plans "SELECT price_vnd FROM membership_plans WHERE id = '$plan_id'")" = 999999 ]
[ "$(sql_member "SELECT price_vnd_snapshot FROM subscriptions WHERE member_id = '$member_id' AND gym_id = '$gym_id'")" = 450000 ]
[ "$(sql_member "SELECT price_vnd_snapshot FROM pending_purchases WHERE id = '$purchase_id'")" = 450000 ]

printf '%s\n' 'G8 business checks passed: register/verify, Plans catalog via HTTP, SelectGym Plans-first, purchase+fake payment, frozen snapshots, replay idempotency, schema ownership, mTLS method allowlist.'

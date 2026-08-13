#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
compose="docker compose -f $root/g9-compose.yml"
base=https://localhost:8443
ca=$root/g9-certs/g9-ca.crt
private=$root/g9-private
status_file=$root/g9-business-status
network=gym-g9_default
email="g9-$(date +%s)@example.test"
password='G9RunnerPass1'
new_password='G9RunnerPass2'
trainer_email="g9-trainer-$(date +%s)@example.test"
capture_container=
step=initializing

umask 077
rm -rf "$private"
mkdir -p "$private"
printf '%s\n' "running: $step" >"$status_file"
cleanup() {
  result=$?
  rm -rf "$private"
  if [ -n "$capture_container" ]; then
    docker rm -f "$capture_container" >/dev/null 2>&1 || true
  fi
  if [ "$result" -ne 0 ]; then
    printf '%s\n' "failed: $step" >"$status_file"
    printf '%s\n' "G9 business check failed at: $step" >&2
  fi
}
trap cleanup EXIT INT TERM

mark() {
  step=$1
  printf '%s\n' "running: $step" >"$status_file"
}

sql_identity() { $compose exec -T identity-postgres psql -U postgres -d identity_db -tA -c "$1"; }
sql_member() { $compose exec -T member-postgres psql -U postgres -d gym_member -tA -c "$1"; }
sql_plans() { $compose exec -T plans-postgres psql -U postgres -d plans_db -tA -c "$1"; }

wait_for() {
  name=$1 command=$2
  for _ in $(seq 1 120); do
    if sh -c "$command" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  printf '%s\n' "Timed out waiting for $name." >&2
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

expect_grpc_metadata_ignored() {
  token=$1
  status=$(curl --cacert "$ca" -sS -o /dev/null -w '%{http_code}' -X POST "$base/api/v1/gyms" \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    -H 'Grpc-Metadata-X-User-Role: SUPER_ADMIN' \
    --data-binary '{"chainId":"forged","name":"forged","address":"forged","city":"forged"}')
  [ "$status" = 403 ]
}

body() { cat "$private/$1.body"; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
fixture_token() {
  expiry=$1 jti=$2 role=${3:-CUSTOMER} sub=${4:-00000000-0000-0000-0000-000000000001}
  now=$(date +%s)
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT","kid":"current"}' | b64url)
  payload=$(printf '{"iss":"gym-identifier","aud":"gym-api","sub":"%s","role":"%s","iat":%s,"exp":%s,"jti":"%s"}' "$sub" "$role" "$now" "$expiry" "$jti" | b64url)
  unsigned=$header.$payload
  signature=$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$root/certs/fixture_rsa.key" | b64url)
  printf '%s.%s' "$unsigned" "$signature"
}

grpcurl_call() {
  cert=$1 service=$2 data=$3 method=$4
  shift 4
  docker run --rm --network "$network" \
    -v "$root/g9-certs:/certs:ro" --user "$(id -u):$(id -g)" \
    fullstorydev/grpcurl:v1.9.1 -cacert /certs/g9-ca.crt \
    -cert "/certs/$cert.crt" -key "/certs/$cert.key" \
    "$@" -servername "$service" -d "$data" "$service:50051" "$method"
}

grpcurl_denied() {
  cert=$1 service=$2 data=$3 method=$4
  shift 4
  set +e
  output=$(grpcurl_call "$cert" "$service" "$data" "$method" "$@" 2>&1)
  code=$?
  set -e
  if [ "$code" -eq 0 ] || ! printf '%s' "$output" | grep -Eqi 'PermissionDenied|PERMISSION_DENIED|permission denied'; then
    printf 'expected PERMISSION_DENIED for %s with %s: %s\n' "$method" "$cert" "$output" >&2
    return 1
  fi
}

grpcurl_tls_fails() {
  cert=$1 address=$2 server_name=$3 data=$4 method=$5
  set +e
  output=$(docker run --rm --network "$network" \
    -v "$root/g9-certs:/certs:ro" --user "$(id -u):$(id -g)" \
    fullstorydev/grpcurl:v1.9.1 -cacert /certs/g9-ca.crt \
    -cert "/certs/$cert.crt" -key "/certs/$cert.key" \
    -servername "$server_name" -d "$data" "$address" "$method" 2>&1)
  code=$?
  set -e
  [ "$code" -ne 0 ]
  printf '%s' "$output" | grep -Eqi 'tls|certificate|x509|handshake'
}

gateway_http_status() {
  cert=$1
  shift
  docker run --rm --network "$network" \
    -v "$root/g9-certs:/certs:ro" --user "$(id -u):$(id -g)" \
    curlimages/curl:8.10.1 --http2 -sS -o /dev/null -w '%{http_code}' \
    --cacert /certs/g9-ca.crt --cert "/certs/$cert.crt" --key "/certs/$cert.key" \
    "$@" https://ms-gym-api-gateway:8443/api/v1/gyms
}

gateway_handshake_fails() {
  cert=$1
  set +e
  output=$(gateway_http_status "$cert" 2>&1)
  code=$?
  set -e
  [ "$code" -ne 0 ] || {
    printf 'expected TLS handshake failure for %s, got: %s\n' "$cert" "$output" >&2
    return 1
  }
}

# Given every manifest route, when its public operation is exercised below, then the real service owns the result.
mark 'starting verification token capture'
capture_container=g9-token-capture
$compose run -d --name "$capture_container" --no-deps schema-seed sh -ec '
  cp -R /source/. /tmp/gym-proto && cd /tmp/gym-proto &&
  ./gradlew captureEmailVerificationToken -PkafkaBrokers=kafka:29092 -PschemaRegistryUrl=http://schema-registry:8081 -Pemail="$1" -PtimeoutSeconds=120 -PoutputPath=/tmp/verification-token --no-daemon 1>&2
' sh "$email" >/dev/null

mark 'Identity Register JSON mapping'
expect_status 200 register POST /api/v1/auth/register '' "{\"email\":\"$email\",\"password\":\"$password\",\"full_name\":\"G9 Customer\"}"
body register | assert_json 'obj["status"] == "USER_STATUS_PENDING_VERIFICATION"'
wait_for 'registered Identity row' "$compose exec -T identity-postgres psql -U postgres -d identity_db -tAc \"SELECT 1 FROM users WHERE email='$email' AND status='PENDING_VERIFICATION'\" | grep -qx 1"
user_id=$(sql_identity "SELECT id FROM users WHERE email='$email'")
wait_for 'Member shell projection' "$compose exec -T member-postgres psql -U postgres -d gym_member -tAc \"SELECT 1 FROM members WHERE user_id='$user_id'\" | grep -qx 1"
member_id=$(sql_member "SELECT id FROM members WHERE user_id='$user_id'")

mark 'Identity VerifyEmail public operation'
wait_for 'verification token capture' "docker inspect -f '{{.State.Running}}' '$capture_container' 2>/dev/null | grep -qx false"
[ "$(docker inspect -f '{{.State.ExitCode}}' "$capture_container")" = 0 ]
verification_token=$(docker cp "$capture_container:/tmp/verification-token" - | tar -xO)
[ -n "$verification_token" ]
docker rm "$capture_container" >/dev/null
capture_container=
expect_status 200 verify POST /api/v1/auth/email/verify '' "{\"verification_token\":\"$verification_token\"}"

mark 'Identity ResendEmailVerification public operation'
expect_status 200 resend POST /api/v1/auth/email/resend '' "{\"email\":\"$email\"}"
access=$(body verify | json_field access_token)
refresh=$(body verify | json_field refresh_token)

mark 'Identity Login public operation'
expect_status 200 login POST /api/v1/auth/login '' "{\"email\":\"$email\",\"password\":\"$password\"}"
access=$(body login | json_field access_token)
refresh=$(body login | json_field refresh_token)
body login | assert_json 'obj["status"] == "USER_STATUS_ACTIVE" and isinstance(obj["expires_in"], int)'

mark 'Identity LoginWithGoogle public negative execution'
expect_status 401 google POST /api/v1/auth/oauth/google '' '{"id_token":"not-a-google-token"}'

mark 'Identity RefreshToken public operation'
expect_status 200 refresh POST /api/v1/auth/refresh '' "{\"refresh_token\":\"$refresh\"}"
access=$(body refresh | json_field access_token)

mark 'Identity GetCurrentUser and forged trusted headers'
printf 'Authorization: Bearer %s\n' "$access" >"$private/me.auth"
me_status=$(curl --cacert "$ca" -sS -w '%{http_code}' -D "$private/me.headers" -o "$private/me.body" \
  -H "@$private/me.auth" -H 'x-user-id: forged-user' -H 'x-user-role: SUPER_ADMIN' \
  -H 'x-gym-id: forged-gym' -H 'x-membership-status: ACTIVE' "$base/api/v1/users/me")
[ "$me_status" = 200 ]
body me | assert_json 'obj["id"] == args[0]' "$user_id"

mark 'Identity ChangePassword protected operation'
expect_status 200 password POST /api/v1/users/password "$access" "{\"old_password\":\"$password\",\"new_password\":\"$new_password\"}"
password=$new_password
expect_status 401 old-login POST /api/v1/auth/login '' "{\"email\":\"$email\",\"password\":\"G9RunnerPass1\"}"

mark 'promoting fixture actor and logging in'
sql_identity "UPDATE users SET role='SUPER_ADMIN' WHERE id='$user_id'" >/dev/null
expect_status 200 admin-login POST /api/v1/auth/login '' "{\"email\":\"$email\",\"password\":\"$password\"}"
admin=$(body admin-login | json_field access_token)

mark 'Plans CreateGymLocation JSON operation'
expect_status 200 gym-create POST /api/v1/gyms "$admin" '{"chainId":"chain-g9","name":"G9 Downtown","address":"9 Gateway Way","city":"Map City"}'
gym_id=$(body gym-create | json_field id)
body gym-create | assert_json 'obj["chainId"] == "chain-g9" and obj["status"] == "GYM_LOCATION_STATUS_ACTIVE"'

mark 'Plans UpdateGymLocation path and enum mapping'
expect_status 200 gym-update PUT "/api/v1/gyms/$gym_id" "$admin" '{"chainId":"chain-g9","name":"G9 Downtown Updated","address":"10 Gateway Way","city":"Map City","status":"GYM_LOCATION_STATUS_ACTIVE"}'
body gym-update | assert_json 'obj["name"] == "G9 Downtown Updated" and obj["status"] == "GYM_LOCATION_STATUS_ACTIVE"'

mark 'Plans GetGymLocation path operation'
expect_status 200 gym-get GET "/api/v1/gyms/$gym_id" "$admin"
body gym-get | assert_json 'obj["id"] == args[0]' "$gym_id"

mark 'Plans ListGymLocations query and enum mapping'
expect_status 200 gym-list GET '/api/v1/gyms?chainId=chain-g9&city=Map%20City&status=GYM_LOCATION_STATUS_ACTIVE' "$admin"
body gym-list | assert_json 'len(obj["locations"]) == 1 and obj["locations"][0]["id"] == args[0]' "$gym_id"

mark 'Plans CreateMembershipPlan enum and int64 mapping'
expect_status 200 plan-create POST "/api/v1/gyms/$gym_id/plans" "$admin" '{"name":"G9 Monthly","planType":"PLAN_TYPE_MONTHLY","durationDays":30,"priceVnd":"450000","description":"gateway mapping","active":true}'
plan_id=$(body plan-create | json_field id)
body plan-create | assert_json 'obj["gymId"] == args[0] and obj["planType"] == "PLAN_TYPE_MONTHLY" and obj["priceVnd"] == "450000" and obj["durationDays"] == 30' "$gym_id"

mark 'Plans UpdateMembershipPlan path enum and int64 mapping'
expect_status 200 plan-update PUT "/api/v1/plans/$plan_id" "$admin" '{"name":"G9 Monthly Updated","planType":"PLAN_TYPE_MONTHLY","durationDays":31,"priceVnd":"450001","description":"updated","active":true}'
body plan-update | assert_json 'obj["priceVnd"] == "450001" and obj["durationDays"] == 31'

mark 'Plans GetMembershipPlan path operation'
expect_status 200 plan-get GET "/api/v1/plans/$plan_id" "$admin"
body plan-get | assert_json 'obj["id"] == args[0] and obj["priceVnd"] == "450001"' "$plan_id"

mark 'Plans ListMembershipPlans query mappings'
expect_status 200 plan-list GET "/api/v1/gyms/$gym_id/plans?planType=PLAN_TYPE_MONTHLY&active=true" "$admin"
body plan-list | assert_json 'len(obj["plans"]) == 1 and obj["plans"][0]["id"] == args[0]' "$plan_id"

mark 'Identity CreateTrainerAccount protected operation'
expect_status 200 trainer POST /api/v1/admin/trainers "$admin" "{\"email\":\"$trainer_email\",\"temp_password\":\"TrainerPass1\",\"gym_id\":\"$gym_id\"}"
trainer_id=$(body trainer | json_field id)
body trainer | assert_json 'obj["role"] == "ROLE_TRAINER" and obj["status"] == "USER_STATUS_ACTIVE"'

mark 'Identity ListUsers query mapping'
expect_status 200 users GET "/api/v1/admin/users?page=0&limit=100&gymId=$gym_id" "$admin"
body users | assert_json 'obj["total"] >= 2 and any(u["id"] == args[0] for u in obj["users"])' "$trainer_id"

mark 'Identity SuspendUser path operation'
expect_status 200 suspend POST "/api/v1/admin/users/$trainer_id/suspend" "$admin" '{}'
[ "$(sql_identity "SELECT status FROM users WHERE id='$trainer_id'")" = SUSPENDED ]

mark 'creating foreign Member fixture for compatibility authorization'
foreign_user_id=$(python3 -c 'import uuid; print(uuid.uuid4())')
foreign_member_id=$(python3 -c 'import uuid; print(uuid.uuid4())')
sql_member "INSERT INTO members (id, user_id, full_name, status) VALUES ('$foreign_member_id', '$foreign_user_id', 'G9 Foreign', 'NONE')" >/dev/null

mark 'Member GetMember path operation'
expect_status 200 member-get GET "/api/v1/members/$member_id" "$admin"
body member-get | assert_json 'obj["id"] == args[0] and obj["userId"] == args[1] and obj["status"] == "MEMBERSHIP_STATUS_NONE"' "$member_id" "$user_id"

mark 'Member UpdateProfile JSON and path mappings'
expect_status 200 member-update PUT "/api/v1/members/$member_id" "$admin" '{"fullName":"G9 Updated","phone":"+15555550909","avatarUrl":"https://example.test/g9.png","dateOfBirth":"1990-09-09"}'
body member-update | assert_json 'obj["fullName"] == "G9 Updated" and obj["dateOfBirth"] == "1990-09-09"'

mark 'Member ListMembers path and query mappings'
expect_status 200 member-list GET "/api/v1/gyms/$gym_id/members?page=0&limit=10" "$admin"
body member-list | assert_json 'obj["total"] == 0 and obj.get("members", []) == []'

mark 'JWT missing invalid expired and forged-role matrix'
expect_status 401 jwt-missing GET /api/v1/users/me
expect_status 401 jwt-invalid GET /api/v1/users/me 'not.a.jwt'
expired=$(fixture_token "$(( $(date +%s) - 1 ))" g9-expired)
expect_status 401 jwt-expired GET /api/v1/users/me "$expired"
sql_identity "UPDATE users SET role='CUSTOMER' WHERE id='$user_id'" >/dev/null
expect_status 200 customer-login POST /api/v1/auth/login '' "{\"email\":\"$email\",\"password\":\"$password\"}"
customer=$(body customer-login | json_field access_token)
expect_status 403 forged-role POST /api/v1/gyms "$customer" '{"chainId":"forged","name":"forged","address":"forged","city":"forged"}'
expect_grpc_metadata_ignored "$customer"

# Given body:"purchase", when flat JSON reaches Kong, then it becomes the required nested purchase message.
mark 'Member PurchaseMembership nested purchase mapping and replacement flow'
expect_status 200 purchase POST "/api/v1/gyms/$gym_id/memberships/purchase" "$customer" "{\"planId\":\"$plan_id\",\"provider\":\"MOMO\",\"discountCode\":\"\",\"idempotencyKey\":\"g9-$user_id-$plan_id\"}"
payment_id=$(body purchase | json_field paymentId)
[ -n "$payment_id" ]
purchase_id=$(sql_member "SELECT id FROM pending_purchases WHERE payment_id='$payment_id'")
[ "$(sql_member "SELECT price_vnd_snapshot FROM pending_purchases WHERE id='$purchase_id'")" = 450001 ]

mark 'replacement payment completion and subscription activation'
complete=$($compose exec -T fake-payment wget -qO- --header='Content-Type: application/json' --post-data="{\"payment_id\":\"$payment_id\"}" http://127.0.0.1:8080/complete)
[ -n "$(printf '%s' "$complete" | json_field event_id)" ]
wait_for 'ACTIVE subscription' "$compose exec -T member-postgres psql -U postgres -d gym_member -tAc \"SELECT status FROM subscriptions WHERE member_id='$member_id' AND gym_id='$gym_id'\" | grep -qx ACTIVE"
[ "$(sql_member "SELECT status FROM pending_purchases WHERE id='$purchase_id'")" = COMPLETED ]

mark 'Member GetMembershipStatus positive operation'
expect_status 200 membership-get GET "/api/v1/gyms/$gym_id/members/$member_id/membership" "$customer"
body membership-get | assert_json 'obj["memberId"] == args[0] and obj["status"] == "MEMBERSHIP_STATUS_ACTIVE"' "$member_id"

mark 'Member PauseMembership exact colon route'
expect_status 200 membership-pause POST "/api/v1/gyms/$gym_id/members/$member_id/membership:pause" "$customer" '{}'
body membership-pause | assert_json 'obj["status"] == "MEMBERSHIP_STATUS_PAUSED"'

mark 'Member ResumeMembership exact colon route'
expect_status 200 membership-resume POST "/api/v1/gyms/$gym_id/members/$member_id/membership:resume" "$customer" '{}'
body membership-resume | assert_json 'obj["status"] == "MEMBERSHIP_STATUS_ACTIVE"'

mark 'Member ListMembers positive after activation'
expect_status 200 member-list-active GET "/api/v1/gyms/$gym_id/members?page=0&limit=1" "$admin"
body member-list-active | assert_json 'obj["total"] == 1 and obj["members"][0]["id"] == args[0]' "$member_id"

# Given direct workload RPCs, when called with each permitted and sibling identity, then SAN method allowlists decide.
mark 'gateway mTLS and direct public service denial matrices'
! $compose port ms-gym-api-gateway 8443 >/dev/null 2>&1
gateway_status=$(gateway_http_status kong)
[ "$gateway_status" -ge 100 ] && [ "$gateway_status" -lt 600 ]
gateway_handshake_fails wrong-client
gateway_handshake_fails wrong-ca-client
grpcurl_denied kong ms-gym-plans "{\"id\":\"$gym_id\"}" plans.v1.PlansService/GetGymLocation -H x-user-id:super-1 -H x-user-role:SUPER_ADMIN
grpcurl_denied kong ms-gym-member "{\"memberId\":\"$member_id\"}" member.v1.MemberService/GetMember -H x-user-id:"$user_id" -H x-user-role:CUSTOMER

mark 'Plans workload positive and negative matrices'
grpcurl_call identifier ms-gym-plans "{\"gymId\":\"$gym_id\"}" plans.v1.PlansService/GetActiveGym | assert_json 'obj["id"] == args[0]' "$gym_id"
grpcurl_denied member-client ms-gym-plans "{\"gymId\":\"$gym_id\"}" plans.v1.PlansService/GetActiveGym
grpcurl_call member-client ms-gym-plans "{\"planId\":\"$plan_id\",\"gymId\":\"$gym_id\"}" plans.v1.PlansService/ResolvePurchasablePlan | assert_json 'obj["planId"] == args[0] and obj["priceVnd"] == "450001"' "$plan_id"
grpcurl_denied identifier ms-gym-plans "{\"planId\":\"$plan_id\",\"gymId\":\"$gym_id\"}" plans.v1.PlansService/ResolvePurchasablePlan
grpcurl_denied wrong-client ms-gym-plans "{\"gymId\":\"$gym_id\"}" plans.v1.PlansService/GetActiveGym
grpcurl_denied ms-gym-api-gateway-client ms-gym-plans "{\"gymId\":\"$gym_id\"}" plans.v1.PlansService/GetActiveGym

mark 'Member workload positive and negative matrices'
grpcurl_call ms-gym-checkin ms-gym-member "{\"memberId\":\"$member_id\",\"gymId\":\"$gym_id\"}" member.v1.MemberService/ValidateMembership | assert_json 'obj["valid"] is True and obj["status"] == "MEMBERSHIP_STATUS_ACTIVE"'
grpcurl_denied ms-gym-notification ms-gym-member "{\"memberId\":\"$member_id\",\"gymId\":\"$gym_id\"}" member.v1.MemberService/ValidateMembership
grpcurl_call ms-gym-notification ms-gym-member "{\"status\":\"MEMBERSHIP_STATUS_ACTIVE\",\"gymIds\":[\"$gym_id\"]}" member.v1.MemberService/ListMembersByStatus | assert_json 'any(m["id"] == args[0] for m in obj["members"])' "$member_id"
grpcurl_denied ms-gym-checkin ms-gym-member "{\"status\":\"MEMBERSHIP_STATUS_ACTIVE\",\"gymIds\":[\"$gym_id\"]}" member.v1.MemberService/ListMembersByStatus
grpcurl_denied ms-gym-api-gateway-client ms-gym-member "{\"memberId\":\"$member_id\",\"gymId\":\"$gym_id\"}" member.v1.MemberService/ValidateMembership
grpcurl_denied ms-gym-api-gateway-client ms-gym-member "{\"status\":\"MEMBERSHIP_STATUS_ACTIVE\",\"gymIds\":[\"$gym_id\"]}" member.v1.MemberService/ListMembersByStatus

grpcurl_tls_fails ms-gym-api-gateway-client ms-gym-member:50051 ms-gym-plans "{\"memberId\":\"$member_id\"}" member.v1.MemberService/GetMember
grpcurl_tls_fails ms-gym-api-gateway-client ms-gym-plans:50051 ms-gym-member "{\"gymId\":\"$gym_id\"}" plans.v1.PlansService/GetGymLocation

# Given exact manifest regexes, when near-collisions and internal RPC paths are requested, then Kong owns 404.
mark 'exact negative routes and collisions'
expect_status 404 no-route GET /api/v1/not-a-route
expect_status 404 retired-gym POST /api/v1/auth/gym '' '{}'
expect_status 404 wrong-auth-method GET /api/v1/auth/login
expect_status 404 trailing-slash GET /api/v1/users/me/ "$customer"
expect_status 404 singular-member GET "/api/v1/member/$member_id" "$customer"
expect_status 404 member-post-collision POST "/api/v1/members/$member_id" "$customer" '{}'
expect_status 404 gym-post-collision POST "/api/v1/gyms/$gym_id" "$customer" '{}'
expect_status 404 plans-member-collision GET "/api/v1/gyms/$gym_id/memberships" "$customer"
expect_status 404 pause-suffix-collision POST "/api/v1/gyms/$gym_id/members/$member_id/membership:paused" "$customer" '{}'
expect_status 404 identity-rpc POST /identity.v1.IdentityService/GetCurrentUser '' '{}'
expect_status 404 member-rpc POST /member.v1.MemberService/GetMember '' '{}'
expect_status 404 plans-rpc POST /plans.v1.PlansService/GetActiveGym '' '{}'
expect_status 404 reflection POST /grpc.reflection.v1.ServerReflection/ServerReflectionInfo '' '{}'

mark 'HTTP rejects direct non-Kong workload access'
expect_status 404 workload-plans-get-active POST /plans.v1.PlansService/GetActiveGym '' "{\"gymId\":\"$gym_id\"}"
expect_status 404 workload-plans-resolve POST /plans.v1.PlansService/ResolvePurchasablePlan '' "{\"planId\":\"$plan_id\",\"gymId\":\"$gym_id\"}"
expect_status 404 workload-member-validate POST /member.v1.MemberService/ValidateMembership '' "{\"memberId\":\"$member_id\",\"gymId\":\"$gym_id\"}"
expect_status 404 workload-member-list POST /member.v1.MemberService/ListMembersByStatus '' "{\"status\":\"MEMBERSHIP_STATUS_ACTIVE\",\"gymIds\":[\"$gym_id\"]}"

mark 'writing compatibility inputs before customer token revocation'
compat_token=$(fixture_token "$(( $(date +%s) + 3600 ))" g9-compat-customer CUSTOMER "$user_id")
cat >"$status_file" <<EOF
G9_CUSTOMER_TOKEN='$compat_token'
G9_FOREIGN_MEMBER_ID='$foreign_member_id'
G9_GYM_ID='$gym_id'
G9_CONFLICT_EMAIL='$email'
EOF

step='Identity Logout and revoked JWT matrix'
expect_status 200 logout POST /api/v1/auth/logout "$customer" "{\"access_token\":\"$customer\"}"
expect_status 401 jwt-revoked GET /api/v1/users/me "$customer"

# Given approved and denied origins, when preflighted, then CORS remains explicit.
step='HTTPS CORS and TLS checks'
approved=$(curl --cacert "$ca" -sS -D - -o /dev/null -X OPTIONS "$base/api/v1/users/me" -H 'Origin: https://localhost:3000' -H 'Access-Control-Request-Method: GET')
printf '%s' "$approved" | grep -qi '^access-control-allow-origin: https://localhost:3000'
printf '%s' "$approved" | grep -qi '^access-control-allow-credentials: true'
denied=$(curl --cacert "$ca" -sS -D - -o /dev/null -X OPTIONS "$base/api/v1/users/me" -H 'Origin: https://evil.example' -H 'Access-Control-Request-Method: GET')
! printf '%s' "$denied" | grep -qi '^access-control-allow-origin:'
echo | openssl s_client -connect localhost:8443 -servername localhost -CAfile "$ca" -verify_return_error 2>/dev/null | grep -q 'Verify return code: 0 (ok)'

printf '%s\n' 'G9 business checks passed: 12 Identity, 7 Member, 8 Plans HTTPS operations; mappings; JWT/trusted-header boundaries; exact route negatives; workload SAN matrices; purchase/payment/subscription flow.'

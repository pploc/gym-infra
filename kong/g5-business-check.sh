#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
compose="docker compose -f $root/g5-compose.yml"
private_dir=$root/g5-private
email="g5-$(date +%s)@example.test"
password='G5RunnerPass1'
header_file=$private_dir/authorization-header
status_file=$root/g5-business-status
capture_container=
step=initializing

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
    printf '%s\n' "G5 business check failed at: $step" >&2
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

wait_for() {
  name=$1
  command=$2
  for _ in $(seq 1 90); do
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
  python3 -c 'import json, sys; value = json.load(sys.stdin).get(sys.argv[1], ""); assert isinstance(value, (str, int, float, bool)); print(value)' "$field"
}

assert_identity_token() {
  python3 -c 'import base64, json, sys
p = sys.stdin.read().strip().split(".")
assert len(p) == 3
claims = json.loads(base64.urlsafe_b64decode(p[1] + "=" * (-len(p[1]) % 4)))
assert "membership_status" not in claims
assert "gym_id" not in claims
assert isinstance(claims.get("iat"), (int, float))
assert isinstance(claims.get("jti"), str) and claims["jti"]
assert claims.get("iss") == "gym-identifier"
assert claims.get("aud") == "gym-api"'
}

post_json() {
  path=$1
  body=$2
  printf '%s' "$body" | curl -fsS -H 'Content-Type: application/json' --data-binary @- "http://localhost:8000$path"
}

authorized_post_json() {
  path=$1
  body=$2
  token=$3
  printf 'Authorization: Bearer %s\n' "$token" >"$header_file"
  printf '%s' "$body" | curl -fsS -H 'Content-Type: application/json' -H "@$header_file" --data-binary @- "http://localhost:8000$path"
  rm -f "$header_file"
}

authorized_status() {
  path=$1
  token=$2
  method=${3:-GET}
  printf 'Authorization: Bearer %s\n' "$token" >"$header_file"
  curl -sS -o /dev/null -w '%{http_code}' -X "$method" -H "@$header_file" "http://localhost:8000$path"
  rm -f "$header_file"
}

capture_container=g5-token-capture
step='starting verification capture'
printf '%s\n' "running: $step" >"$status_file"
$compose run -d --name "$capture_container" --no-deps schema-seed sh -ec '
  cp -R /source/. /tmp/gym-proto &&
  cd /tmp/gym-proto &&
  ./gradlew captureEmailVerificationToken -PkafkaBrokers=kafka:29092 -PschemaRegistryUrl=http://schema-registry:8081 -Pemail="$1" -PtimeoutSeconds=90 -PoutputPath=/tmp/verification-token --no-daemon 1>&2
' sh "$email" >/dev/null

step='registering customer'
printf '%s\n' "running: $step" >"$status_file"
register_response=$(post_json /api/v1/auth/register "{\"email\":\"$email\",\"password\":\"$password\",\"full_name\":\"G5 Runner\"}")
[ "$(printf '%s' "$register_response" | json_field status)" = 'PENDING_VERIFICATION' ]

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
verify_refresh=$(printf '%s' "$verify_response" | json_field refresh_token)
printf '%s' "$verify_access" | assert_identity_token
[ -n "$verify_refresh" ]

step='logging in customer'
printf '%s\n' "running: $step" >"$status_file"
login_response=$(post_json /api/v1/auth/login "{\"email\":\"$email\",\"password\":\"$password\"}")
login_access=$(printf '%s' "$login_response" | json_field access_token)
login_refresh=$(printf '%s' "$login_response" | json_field refresh_token)
printf '%s' "$login_access" | assert_identity_token
[ -n "$login_refresh" ]

step='refreshing customer token'
printf '%s\n' "running: $step" >"$status_file"
refresh_response=$(post_json /api/v1/auth/refresh "{\"refresh_token\":\"$login_refresh\"}")
refresh_access=$(printf '%s' "$refresh_response" | json_field access_token)
printf '%s' "$refresh_access" | assert_identity_token

step='seeding gym memberships'
printf '%s\n' "running: $step" >"$status_file"
sql_member "
  INSERT INTO gym_locations (id, chain_id, name, address, city, status)
  VALUES
    ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'G5 Active Gym', '1 Test Way', 'Test City', 'ACTIVE'),
    ('22222222-2222-2222-2222-222222222222', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'G5 Paused Gym', '2 Test Way', 'Test City', 'ACTIVE');
  INSERT INTO membership_plans (id, gym_id, name, plan_type, duration_days, price_vnd)
  VALUES
    ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', 'G5 Active Plan', 'MONTHLY', 30, 1),
    ('44444444-4444-4444-4444-444444444444', '22222222-2222-2222-2222-222222222222', 'G5 Paused Plan', 'MONTHLY', 30, 1);
  INSERT INTO subscriptions (id, member_id, plan_id, gym_id, status, start_date, end_date, remaining_days)
  VALUES
    ('55555555-5555-5555-5555-555555555555', '$member_id', '33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', 'ACTIVE', CURRENT_DATE, CURRENT_DATE + 30, 30),
    ('66666666-6666-6666-6666-666666666666', '$member_id', '44444444-4444-4444-4444-444444444444', '22222222-2222-2222-2222-222222222222', 'PAUSED', CURRENT_DATE, NULL, 30);
" >/dev/null

step='checking retired gym-selection route'
printf '%s\n' "running: $step" >"$status_file"
[ "$(authorized_status /api/v1/auth/gym "$login_access" POST)" = 404 ]

step='logging out customer'
printf '%s\n' "running: $step" >"$status_file"
authorized_post_json /api/v1/auth/logout "{\"access_token\":\"$refresh_access\"}" "$refresh_access" >/dev/null
[ "$(authorized_status /api/v1/users/me "$refresh_access")" = 401 ]

step='suspending customer across gyms'
printf '%s\n' "running: $step" >"$status_file"
sql_identity "UPDATE users SET role = 'ADMIN' WHERE id = '$user_id'" >/dev/null
admin_response=$(post_json /api/v1/auth/login "{\"email\":\"$email\",\"password\":\"$password\"}")
admin_access=$(printf '%s' "$admin_response" | json_field access_token)
authorized_post_json "/api/v1/admin/users/$user_id/suspend" "{\"user_id\":\"$user_id\"}" "$admin_access" >/dev/null
wait_for 'Identifier suspension publication' "$compose exec -T identity-postgres psql -U postgres -d identity_db -tAc \"SELECT count(*) FROM outbox_events WHERE key = '$user_id' AND topic = 'identity.user.suspended.v1' AND status = 'PUBLISHED'\" | grep -qx 1"
wait_for 'Member multi-gym suspension projection' "$compose exec -T member-postgres psql -U postgres -d gym_member -tAc \"SELECT count(*) FROM subscriptions WHERE member_id = '$member_id' AND status = 'EXPIRED'\" | grep -qx 2"
[ "$(sql_member "SELECT status FROM members WHERE id = '$member_id'")" = EXPIRED ]
[ "$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' --data-binary @- http://localhost:8000/api/v1/auth/login <<EOF
{"email":"$email","password":"$password"}
EOF
)" = 403 ]

step='recovering outbox after Kafka outage'
printf '%s\n' "running: $step" >"$status_file"
outage_email="g5-outage-$(date +%s)@example.test"
$compose stop kafka >/dev/null
outage_response=$(post_json /api/v1/auth/register "{\"email\":\"$outage_email\",\"password\":\"$password\",\"full_name\":\"G5 Outage\"}")
[ "$(printf '%s' "$outage_response" | json_field status)" = 'PENDING_VERIFICATION' ]
outage_user_id=$(sql_identity "SELECT id FROM users WHERE email = '$outage_email'")
wait_for 'outage outbox persistence' "$compose exec -T identity-postgres psql -U postgres -d identity_db -tAc \"SELECT count(*) FROM outbox_events WHERE key = '$outage_user_id' AND status <> 'PUBLISHED'\" | grep -Eq '^[2-9]$|^[1-9][0-9]+$'"
$compose start kafka >/dev/null
wait_for 'Kafka recovery' "$compose exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list >/dev/null"
wait_for 'outage outbox recovery' "$compose exec -T identity-postgres psql -U postgres -d identity_db -tAc \"SELECT count(*) FROM outbox_events WHERE key = '$outage_user_id' AND status = 'PUBLISHED'\" | grep -Eq '^[2-9]$|^[1-9][0-9]+$'"

printf '%s\n' 'G5 business checks passed: registration, event projection, verification, identity-only tokens, retired gym-selection route, logout blacklist, multi-gym suspension, and outbox recovery.'

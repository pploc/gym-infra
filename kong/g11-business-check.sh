#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
base=${G11_BASE_URL:-https://localhost:8443}
ca=${G11_CA_CERT:-$root/g11-certs/g11-ca.crt}
compose="docker compose -f $root/g11-compose.yml"
secret=${G11_SEPAY_WEBHOOK_SECRET:?G11_SEPAY_WEBHOOK_SECRET is required}
reference=${G11_PAYMENT_REFERENCE_CODE:?G11_PAYMENT_REFERENCE_CODE from InitiatePayment is required}
amount=${G11_PAYMENT_AMOUNT_VND:?G11_PAYMENT_AMOUNT_VND is required}
purchase=${G11_PURCHASE_ID:?G11_PURCHASE_ID is required}

account=${G11_SEPAY_ACCOUNT_NUMBER:-g11-account}
received=$((amount + 1))
body=$(printf '{"id":11001,"accountNumber":"%s","code":"%s","transferType":"in","transferAmount":%s,"content":"G11 membership overpay","referenceCode":"g11-callback-overpay"}' "$account" "$reference" "$received")
timestamp=$(date +%s)
signature=$(python3 - "$secret" "$timestamp" "$body" <<'PY'
import hashlib,hmac,sys
print("sha256=" + hmac.new(sys.argv[1].encode(), f"{sys.argv[2]}.{sys.argv[3]}".encode(), hashlib.sha256).hexdigest())
PY
)
post() {
  printf '%s' "$body" | curl --cacert "$ca" -fsS -X POST \
    -H 'Content-Type: application/json' \
    -H "X-SePay-Timestamp: $timestamp" \
    -H "X-SePay-Signature: $signature" \
    --data-binary @- "$base/api/v1/payments/webhook/sepay"
}

# Overpayment completes with a frozen event amount; exact replay must not add a second event.
post >/dev/null
post >/dev/null
[ "$($compose exec -T payment-postgres psql -U postgres -d payment_db -tAc "SELECT intent_amount_vnd FROM payment_intents WHERE payment_code='$reference'" | tr -d '[:space:]')" = "$amount" ]
[ "$($compose exec -T payment-postgres psql -U postgres -d payment_db -tAc "SELECT received_amount_vnd FROM payment_intents WHERE payment_code='$reference'" | tr -d '[:space:]')" = "$received" ]
[ "$($compose exec -T payment-postgres psql -U postgres -d payment_db -tAc "SELECT count(*) FROM outbox_events WHERE dedupe_key = 'payment.completed.v1:' || (SELECT id FROM payment_intents WHERE payment_code='$reference')" | tr -d '[:space:]')" = 1 ]

for _ in $(seq 1 120); do
  state=$($compose exec -T member-postgres psql -U postgres -d gym_member -tAc "SELECT status FROM pending_purchases WHERE id='$purchase'" | tr -d '[:space:]')
  count=$($compose exec -T member-postgres psql -U postgres -d gym_member -tAc "SELECT count(*) FROM subscriptions s JOIN pending_purchases p ON p.member_id=s.member_id AND p.gym_id=s.gym_id WHERE p.id='$purchase' AND s.status='ACTIVE'" | tr -d '[:space:]')
  [ "$state" = COMPLETED ] && [ "$count" = 1 ] && {
    python3 - <<'PY'
import yaml
print(yaml.safe_dump({
    "schemaVersion": 1,
    "mode": "source-build-pending-payment-image",
    "gates": {"result": "passed", "exitCodes": {"business": 0}},
    "checks": [
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

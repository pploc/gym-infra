#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
base=${G10_BASE_URL:-https://localhost:8443}
ca=${G10_CA_CERT:-$root/g10-certs/g10-ca.crt}
lock=$root/g10-release-lock.json
raw=${G10_RAW_EVIDENCE:-$root/g10-raw-evidence.yaml}

umask 077
status=0
run_case() {
  name=$1 expected=$2 method=$3 path=$4
  actual=$(curl --cacert "$ca" -sS -o /dev/null -w '%{http_code}' -X "$method" "$base$path" || true)
  [ "$actual" = "$expected" ] || status=1
  printf '%s\t%s\t%s\n' "$name" "$actual" "$([ "$actual" = "$expected" ] && printf passed || printf failed)"
}

run_case health 404 GET /status
run_case unknown_route 404 GET /api/v1/not-a-route
run_case missing_jwt 401 GET /api/v1/users/me
run_case direct_grpc_path 404 POST /checkin.v1.CheckInService/Scan
run_case trailing_slash 404 GET /api/v1/users/me/

python3 - "$lock" "$status" "$raw" <<'PY'
import json, sys
from pathlib import Path
lock = json.loads(Path(sys.argv[1]).read_text())
status = int(sys.argv[2])
checks = [
    {"name": "route_and_auth_negative_matrix", "result": "passed" if status == 0 else "failed", "exitCode": status},
]
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
Path(sys.argv[3]).write_text(__import__('yaml').safe_dump(evidence, sort_keys=False))
if status:
    raise SystemExit(status)
PY
printf '%s\n' 'G10 business negative matrix passed.'

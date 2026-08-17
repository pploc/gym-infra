#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
lock=$root/g10-release-lock.json

python3 "$root/validate-g10-lock.py" "$lock"
status=$(python3 - "$lock" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["status"])
PY
)
[ "$status" = draft-not-release-evidence ] || {
  printf '%s\n' 'G10 runner only accepts draft lock before explicit publication authorization.' >&2
  exit 1
}
printf '%s\n' 'G10 fixture scaffold validated. Final immutable images and release checksums require explicit authorization.'

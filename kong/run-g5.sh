#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
: "${GITHUB_ACTOR:?GITHUB_ACTOR is required to build private dependencies}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required to build private dependencies}"

cleanup() {
  docker compose -f "$root/g5-compose.yml" down --remove-orphans
  rm -rf "$root/g5-certs"
}
failed() {
  {
    docker compose -f "$root/g5-compose.yml" ps -a
    docker compose -f "$root/g5-compose.yml" logs --no-color
  } >"$root/g5-last-run.log" 2>&1 || true
  cat "$root/g5-last-run.log" >&2
  exit 1
}
trap cleanup EXIT INT TERM

if ! "$root/generate-g5-certs.sh" "$root/g5-certs"; then
  failed
fi
if ! docker compose -f "$root/g5-compose.yml" config >/dev/null; then
  failed
fi
if ! docker compose -f "$root/g5-compose.yml" up -d --build; then
  failed
fi

for _ in $(seq 1 180); do
  if curl -fsS http://localhost:8001/status >/dev/null 2>&1; then
    status=$(curl -sS -o /dev/null -w '%{http_code}' -X POST http://localhost:8000/api/v1/auth/login) || failed
    if [ "$status" -ge 400 ] && [ "$status" -lt 500 ]; then
      if ! "$root/g5-business-check.sh"; then
        failed
      fi
      echo 'G5 Identifier-led business checks passed. Member external HTTP routes remain intentionally unexposed.'
      exit 0
    fi
    failed
  fi
  sleep 1
done

printf '%s\n' 'Kong did not become ready within 180 seconds.' >&2
failed

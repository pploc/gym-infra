#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
: "${GITHUB_ACTOR:?GITHUB_ACTOR is required to build private dependencies}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required to build private dependencies}"

cleanup() {
  docker compose -f "$root/g8-compose.yml" down --remove-orphans
  rm -rf "$root/g8-certs"
}
failed() {
  {
    docker compose -f "$root/g8-compose.yml" ps -a
    docker compose -f "$root/g8-compose.yml" logs --no-color
  } >"$root/g8-last-run.log" 2>&1 || true
  cat "$root/g8-last-run.log" >&2
  exit 1
}
trap cleanup EXIT INT TERM

if ! "$root/generate-g8-certs.sh" "$root/g8-certs"; then
  failed
fi
if ! docker compose -f "$root/g8-compose.yml" config >/dev/null; then
  failed
fi
if ! docker compose -f "$root/g8-compose.yml" up -d --build; then
  failed
fi

for _ in $(seq 1 240); do
  if curl -fsS http://localhost:8001/status >/dev/null 2>&1; then
    status=$(curl -sS -o /dev/null -w '%{http_code}' -X POST http://localhost:8000/api/v1/auth/login) || failed
    if [ "$status" -ge 400 ] && [ "$status" -lt 500 ]; then
      if ! "$root/g8-business-check.sh"; then
        failed
      fi
      echo 'G8 three-service business checks passed. Member public HTTP remains intentionally unexposed.'
      exit 0
    fi
    failed
  fi
  sleep 1
done

printf '%s\n' 'Kong did not become ready within 240 seconds.' >&2
failed

#!/bin/sh
set -eu

[ "$#" -eq 1 ] || {
  printf '%s\n' 'usage: verify-openapi-types.sh OPENAPI_YAML' >&2
  exit 64
}

input=$1
[ -f "$input" ] || {
  printf 'OpenAPI document not found: %s\n' "$input" >&2
  exit 1
}

workspace=$(mktemp -d "${TMPDIR:-/tmp}/gym-openapi-types.XXXXXX")
cleanup() {
  rm -rf "$workspace"
}
trap cleanup EXIT INT TERM

output=$workspace/gym-active-api.ts
npm exec --yes --package=openapi-typescript@7.6.1 -- \
  openapi-typescript "$input" --output "$output"
npm exec --yes --package=typescript@5.7.3 -- \
  tsc --noEmit --strict --target ES2022 --module NodeNext --moduleResolution NodeNext "$output"
printf '%s\n' 'Released canonical OpenAPI TypeScript generation and type-check passed.'

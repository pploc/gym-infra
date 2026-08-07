#!/bin/sh
set -eu

out=${1:-"$(dirname "$0")/g5-certs"}
rm -rf "$out"
mkdir -p "$out"
trap 'rm -f "$out"/*.csr "$out"/*.ext "$out"/*.srl' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "$out/ca.key" \
  -out "$out/ca.crt" \
  -subj '/CN=gym-g5-test-ca' >/dev/null 2>&1

issue() {
  name=$1
  san=$2
  usage=$3
  openssl req -newkey rsa:2048 -nodes \
    -keyout "$out/$name.key" \
    -out "$out/$name.csr" \
    -subj "/CN=$name" >/dev/null 2>&1
  printf 'subjectAltName=%s\nextendedKeyUsage=%s\n' "$san" "$usage" >"$out/$name.ext"
  openssl x509 -req -days 1 \
    -in "$out/$name.csr" \
    -CA "$out/ca.crt" \
    -CAkey "$out/ca.key" \
    -CAcreateserial \
    -out "$out/$name.crt" \
    -extfile "$out/$name.ext" >/dev/null 2>&1
}

issue member 'DNS:ms-gym-member' serverAuth
issue identifier 'DNS:ms-gym-identifier,URI:spiffe://gym.cluster.local/ns/gym-system/sa/ms-gym-identifier' clientAuth
chmod 600 "$out"/*.key

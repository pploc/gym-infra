#!/bin/sh
set -eu

out=${1:-"$(dirname "$0")/g8-certs"}
rm -rf "$out"
mkdir -p "$out"
trap 'rm -f "$out"/*.csr "$out"/*.ext "$out"/*.srl' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "$out/ca.key" \
  -out "$out/ca.crt" \
  -subj '/CN=gym-g8-test-ca' >/dev/null 2>&1

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

issue plans 'DNS:ms-gym-plans' serverAuth
issue member 'DNS:ms-gym-member' serverAuth
issue identifier 'DNS:ms-gym-identifier,URI:spiffe://gym.cluster.local/ns/gym-system/sa/ms-gym-identifier' clientAuth
issue member-client 'DNS:ms-gym-member,URI:spiffe://gym.cluster.local/ns/gym-system/sa/ms-gym-member' clientAuth
issue kong 'DNS:kong,URI:spiffe://gym.cluster.local/ns/gym-system/sa/kong' clientAuth
issue checkin 'DNS:ms-gym-checkin,URI:spiffe://gym.cluster.local/ns/gym-system/sa/ms-gym-checkin' clientAuth
issue notification 'DNS:ms-gym-notification,URI:spiffe://gym.cluster.local/ns/gym-system/sa/ms-gym-notification' clientAuth
# Disposable local fixtures only. grpcurl image is non-root and must read client keys.
chmod 644 "$out"/*.crt "$out"/*.key

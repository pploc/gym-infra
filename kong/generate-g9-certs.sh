#!/bin/sh
set -eu

out=${1:-"$(dirname "$0")/g9-certs"}
rm -rf "$out"
mkdir -p "$out"
trap 'rm -f "$out"/*.csr "$out"/*.ext "$out"/*.srl' EXIT

make_ca() {
  name=$1
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$out/$name.key" -out "$out/$name.crt" \
    -subj "/CN=$name" -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
}

issue() {
  ca=$1
  name=$2
  san=$3
  usage=$4
  openssl req -newkey rsa:2048 -nodes \
    -keyout "$out/$name.key" -out "$out/$name.csr" \
    -subj "/CN=$name" >/dev/null 2>&1
  cat >"$out/$name.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
subjectAltName=$san
extendedKeyUsage=$usage
EOF
  openssl x509 -req -days 1 -in "$out/$name.csr" \
    -CA "$out/$ca.crt" -CAkey "$out/$ca.key" -CAcreateserial \
    -out "$out/$name.crt" -extfile "$out/$name.ext" >/dev/null 2>&1
}

make_ca g9-ca
make_ca g9-wrong-ca
issue g9-ca ms-gym-member 'DNS:ms-gym-member' serverAuth
issue g9-ca ms-gym-plans 'DNS:ms-gym-plans' serverAuth
issue g9-ca kong-proxy 'DNS:localhost' serverAuth
issue g9-ca kong 'DNS:kong,URI:spiffe://gym.cluster.local/ns/gym-system/sa/kong' clientAuth
issue g9-ca ms-gym-api-gateway-server 'DNS:ms-gym-api-gateway' serverAuth
issue g9-ca ms-gym-api-gateway-client 'DNS:ms-gym-api-gateway,URI:spiffe://gym.cluster.local/ns/gym-system/sa/ms-gym-api-gateway' clientAuth
issue g9-ca identifier 'DNS:ms-gym-identifier,URI:spiffe://gym.cluster.local/ns/gym-system/sa/ms-gym-identifier' clientAuth
issue g9-ca member-client 'DNS:ms-gym-member,URI:spiffe://gym.cluster.local/ns/gym-system/sa/ms-gym-member' clientAuth
issue g9-ca ms-gym-checkin 'DNS:ms-gym-checkin,URI:spiffe://gym.cluster.local/ns/gym-system/sa/ms-gym-checkin' clientAuth
issue g9-ca ms-gym-notification 'DNS:ms-gym-notification,URI:spiffe://gym.cluster.local/ns/gym-system/sa/ms-gym-notification' clientAuth
issue g9-ca wrong-client 'DNS:not-kong,URI:spiffe://gym.cluster.local/ns/gym-system/sa/not-kong' clientAuth
issue g9-wrong-ca wrong-ca-client 'DNS:kong,URI:spiffe://gym.cluster.local/ns/gym-system/sa/kong' clientAuth
rm -f "$out/g9-ca.key" "$out/g9-wrong-ca.key"

# Host-only negative fixtures stay at the root; containers receive only their own material.
for service in plans member identifier kong gateway; do
  mkdir -p "$out/runtime/$service"
  cp "$out/g9-ca.crt" "$out/runtime/$service/"
done
cp "$out/ms-gym-plans.crt" "$out/ms-gym-plans.key" "$out/runtime/plans/"
cp "$out/ms-gym-member.crt" "$out/ms-gym-member.key" \
  "$out/member-client.crt" "$out/member-client.key" "$out/runtime/member/"
cp "$out/identifier.crt" "$out/identifier.key" "$out/runtime/identifier/"
cp "$out/kong-proxy.crt" "$out/kong-proxy.key" \
  "$out/kong.crt" "$out/kong.key" "$out/runtime/kong/"
cp "$out/ms-gym-api-gateway-server.crt" "$out/ms-gym-api-gateway-server.key" \
  "$out/ms-gym-api-gateway-client.crt" "$out/ms-gym-api-gateway-client.key" \
  "$out/runtime/gateway/"

# Disposable local fixtures only. Containers and host grpcurl run as non-root users.
find "$out" -type f \( -name '*.crt' -o -name '*.key' \) -exec chmod 644 {} +

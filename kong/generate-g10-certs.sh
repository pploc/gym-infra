#!/bin/sh
set -eu

out=${1:-"$(dirname "$0")/g10-certs"}
rm -rf "$out"
mkdir -p "$out"
trap 'rm -f "$out"/*.csr "$out"/*.ext "$out"/*.srl' EXIT

make_ca() {
  name=$1
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout "$out/$name.key" -out "$out/$name.crt" \
    -subj "/CN=$name" -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
}

issue() {
  ca=$1 name=$2 san=$3 usage=$4
  openssl req -newkey rsa:2048 -nodes -keyout "$out/$name.key" -out "$out/$name.csr" -subj "/CN=$name" >/dev/null 2>&1
  cat >"$out/$name.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
subjectAltName=$san
extendedKeyUsage=$usage
EOF
  openssl x509 -req -days 1 -in "$out/$name.csr" -CA "$out/$ca.crt" -CAkey "$out/$ca.key" -CAcreateserial \
    -out "$out/$name.crt" -extfile "$out/$name.ext" >/dev/null 2>&1
}

make_ca g10-ca
make_ca g10-wrong-ca
issue g10-ca ms-gym-checkin 'DNS:ms-gym-checkin' serverAuth
issue g10-ca ms-gym-api-gateway-server 'DNS:ms-gym-api-gateway' serverAuth
issue g10-ca ms-gym-api-gateway-client 'DNS:ms-gym-api-gateway,URI:spiffe://gym.cluster.local/ns/gym-system/sa/ms-gym-api-gateway' clientAuth
issue g10-ca kong-proxy 'DNS:localhost' serverAuth
issue g10-ca kong 'DNS:kong,URI:spiffe://gym.cluster.local/ns/gym-system/sa/kong' clientAuth
issue g10-ca checkin-client 'DNS:ms-gym-checkin,URI:spiffe://gym.cluster.local/ns/gym-system/sa/ms-gym-checkin' clientAuth
issue g10-ca wrong-client 'DNS:not-gateway,URI:spiffe://gym.cluster.local/ns/gym-system/sa/not-gateway' clientAuth
issue g10-wrong-ca wrong-ca-client 'DNS:ms-gym-api-gateway,URI:spiffe://gym.cluster.local/ns/gym-system/sa/ms-gym-api-gateway' clientAuth
rm -f "$out/g10-ca.key" "$out/g10-wrong-ca.key"

mkdir -p "$out/runtime/checkin" "$out/runtime/gateway" "$out/runtime/kong"
cp "$out/g10-ca.crt" "$out/runtime/checkin/"
cp "$out/ms-gym-checkin.crt" "$out/ms-gym-checkin.key" "$out/checkin-client.crt" "$out/checkin-client.key" "$out/runtime/checkin/"
cp "$out/g10-ca.crt" "$out/ms-gym-api-gateway-server.crt" "$out/ms-gym-api-gateway-server.key" \
  "$out/ms-gym-api-gateway-client.crt" "$out/ms-gym-api-gateway-client.key" "$out/runtime/gateway/"
cp "$out/g10-ca.crt" "$out/kong-proxy.crt" "$out/kong-proxy.key" "$out/kong.crt" "$out/kong.key" "$out/runtime/kong/"
find "$out" -type f \( -name '*.crt' -o -name '*.key' \) -exec chmod 644 {} +

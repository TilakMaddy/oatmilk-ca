#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CA_DIR="$BASE_DIR/oatca"

usage() {
  echo "Usage: $0 [--force]"
  echo ""
  echo "  Initialize the Oatmilk CA. Generates a 4096-bit RSA key"
  echo "  and a self-signed root certificate (100 years)."
  echo ""
  echo "  Options:"
  echo "    --force   Regenerate the CA (destroys existing key + cert)."
  echo "              All server certs signed by this CA become invalid."
  exit 1
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
fi

# Safety check — refuse to overwrite unless --force is passed
if [[ -f "$CA_DIR/ca.key" ]]; then
  if [[ "${1:-}" == "--force" ]]; then
    echo "==> --force passed, regenerating CA..."
    echo "    WARNING: All existing server certs signed by this CA will become invalid."
    rm -f "$CA_DIR/ca.key" "$CA_DIR/ca.crt" "$CA_DIR/ca.srl"
  else
    echo "ERROR: CA already exists at $CA_DIR/ca.key"
    echo ""
    echo "  To regenerate the CA (invalidates all server certs):"
    echo "    $0 --force"
    exit 1
  fi
fi

mkdir -p "$CA_DIR"

if [[ ! -f "$CA_DIR/san_ca.cnf" ]]; then
  echo "==> san_ca.cnf not found — generating default config..."
  cat > "$CA_DIR/san_ca.cnf" <<'CNFEOF'
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
prompt = no

[req_distinguished_name]
C = IN
ST = Karnataka
L = Bangalore
O = Oatmilk
OU = Oatmilk Certificate Authority
CN = oatmilk.work.
emailAddress = ca@oatmilk.work

[v3_req]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectAltName = @alt_names

[alt_names]
DNS.1 = oatmilk.work
DNS.2 = *.oatmilk.work
DNS.3 = backoffice.oatmilk.work
DNS.4 = *.backoffice.oatmilk.work
DNS.5 = remote.backoffice.oatmilk.work
DNS.6 = *.remote.backoffice.oatmilk.work
DNS.7 = home.backoffice.oatmilk.work
DNS.8 = *.home.backoffice.oatmilk.work
CNFEOF
  echo "    Created $CA_DIR/san_ca.cnf"
  echo "    Edit this file if you need to change the CA's distinguished name."
fi

echo "==> Generating CA private key (4096-bit RSA)..."
openssl genrsa -out "$CA_DIR/ca.key" 4096

echo "==> Generating self-signed CA certificate (100 years)..."
openssl req -x509 -new -nodes \
  -key "$CA_DIR/ca.key" \
  -sha256 \
  -days 36500 \
  -out "$CA_DIR/ca.crt" \
  -config "$CA_DIR/san_ca.cnf" \
  -extensions v3_req

# Verify the cert was actually created (catches interactive prompt failures)
if [[ ! -f "$CA_DIR/ca.crt" ]]; then
  echo ""
  echo "ERROR: CA certificate was not created. The openssl command may have failed."
  echo "  Cleaning up partial state..."
  rm -f "$CA_DIR/ca.key"
  exit 1
fi

echo ""
echo "==> CA initialized successfully."
echo "    Key:  $CA_DIR/ca.key"
echo "    Cert: $CA_DIR/ca.crt"

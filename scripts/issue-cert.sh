#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CA_DIR="$BASE_DIR/oatca"

RENEW=false
FOREVER=false
DAYS=365
OU="Backoffice"
EMAIL="team@backoffice.oatmilk.work"

usage() {
  echo "Usage: $0 [options] <server-name> <domain> [additional-domains...]"
  echo ""
  echo "  Issue a server certificate signed by the Oatmilk CA."
  echo ""
  echo "  Examples:"
  echo "    $0 traefik oatmilk.work \"*.oatmilk.work\""
  echo "    $0 --renew traefik oatmilk.work \"*.oatmilk.work\""
  echo "    $0 --forever --ou Engineering traefik oatmilk.work"
  echo ""
  echo "  Options:"
  echo "    --renew          Reuse existing server key, only regenerate CSR and cert."
  echo "                     Use this when the cert is expiring but the key is fine."
  echo "    --forever        No expiry (100 years). Default is 1 year."
  echo "    --ou <name>      Organizational unit (default: Backoffice)"
  echo "    --email <addr>   Email address (default: team@backoffice.oatmilk.work)"
  exit 1
}

# Parse optional flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --renew)
      RENEW=true
      shift
      ;;
    --forever)
      FOREVER=true
      DAYS=36500
      shift
      ;;
    --ou)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --ou requires a value."
        echo "  Example: $0 --ou Engineering traefik oatmilk.work"
        exit 1
      fi
      OU="$2"
      shift 2
      ;;
    --email)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --email requires a value."
        echo "  Example: $0 --email ops@oatmilk.work traefik oatmilk.work"
        exit 1
      fi
      EMAIL="$2"
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    --*)
      echo "ERROR: Unknown option '$1'"
      echo ""
      usage
      ;;
    *)
      break
      ;;
  esac
done

# Validate args — need at least server name + one domain
if [[ $# -lt 2 ]]; then
  if [[ $# -eq 1 ]]; then
    echo "ERROR: Missing domain argument. You provided a server name but no domain."
    echo ""
    echo "  $0 $1 <domain> [additional-domains...]"
    echo "  $0 $1 oatmilk.work \"*.oatmilk.work\""
  else
    echo "ERROR: Missing arguments."
  fi
  echo ""
  usage
fi

SERVER_NAME="$1"
shift
DOMAINS=("$@")

# Check that CA exists
if [[ ! -f "$CA_DIR/ca.crt" || ! -f "$CA_DIR/ca.key" ]]; then
  echo "ERROR: CA not found at $CA_DIR/"
  echo ""
  if [[ -f "$CA_DIR/ca.crt" && ! -f "$CA_DIR/ca.key" ]]; then
    echo "  ca.crt exists but ca.key is missing — the CA key may have been lost."
    echo "  Regenerate the CA:"
    echo "    $SCRIPT_DIR/init-ca.sh --force"
  elif [[ ! -f "$CA_DIR/ca.crt" && -f "$CA_DIR/ca.key" ]]; then
    echo "  ca.key exists but ca.crt is missing — partial CA state."
    echo "  Regenerate the CA:"
    echo "    $SCRIPT_DIR/init-ca.sh --force"
  else
    echo "  Initialize the CA first:"
    echo "    $SCRIPT_DIR/init-ca.sh"
  fi
  exit 1
fi

SERVER_DIR="$BASE_DIR/servers/$SERVER_NAME"

# For --renew, check the key exists before we do anything else
if [[ "$RENEW" == true && ! -f "$SERVER_DIR/server.key" ]]; then
  echo "ERROR: --renew specified but no existing key at $SERVER_DIR/server.key"
  echo ""
  echo "  --renew reuses an existing private key. This server has no key to reuse."
  echo ""
  echo "  To issue a fresh certificate instead (generates a new key):"
  echo "    $0 $SERVER_NAME ${DOMAINS[*]}"
  exit 1
fi

mkdir -p "$SERVER_DIR"

# Generate san_server.cnf with prompt=no and hardcoded DN defaults
{
  cat <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
prompt = no

[req_distinguished_name]
C = IN
ST = Karnataka
L = Bangalore
O = Oatmilk
OU = ${OU}
CN = ${DOMAINS[0]}
emailAddress = ${EMAIL}

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
EOF
  for i in "${!DOMAINS[@]}"; do
    echo "DNS.$((i + 1)) = ${DOMAINS[$i]}"
  done
} > "$SERVER_DIR/san_server.cnf"

echo "==> Generated $SERVER_DIR/san_server.cnf"

if [[ "$RENEW" == true ]]; then
  echo "==> Renewing: reusing existing server key"
else
  if [[ -f "$SERVER_DIR/server.key" ]]; then
    echo "==> Overwriting existing cert for $SERVER_NAME (generating new key)"
  fi
  echo "==> Generating server private key (2048-bit RSA)..."
  openssl genrsa -out "$SERVER_DIR/server.key" 2048
fi

echo "==> Generating CSR..."
openssl req -new \
  -key "$SERVER_DIR/server.key" \
  -out "$SERVER_DIR/server.csr" \
  -config "$SERVER_DIR/san_server.cnf"

if [[ "$FOREVER" == true ]]; then
  echo "==> Signing certificate with CA (no expiry)..."
else
  echo "==> Signing certificate with CA (1 year validity)..."
fi
openssl x509 -req \
  -in "$SERVER_DIR/server.csr" \
  -CA "$CA_DIR/ca.crt" \
  -CAkey "$CA_DIR/ca.key" \
  -CAcreateserial \
  -out "$SERVER_DIR/server.crt" \
  -days "$DAYS" \
  -sha256 \
  -copy_extensions copyall

echo ""
echo "==> Certificate issued for $SERVER_NAME"
echo "    Key:  $SERVER_DIR/server.key"
echo "    CSR:  $SERVER_DIR/server.csr"
echo "    Cert: $SERVER_DIR/server.crt"
echo ""
echo "==> Certificate details:"
echo ""
openssl x509 -in "$SERVER_DIR/server.crt" -noout \
  -subject -issuer -dates -serial -ext subjectAltName

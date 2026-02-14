#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVERS_DIR="$BASE_DIR/servers"

RENEW=false

usage() {
  echo "Usage: $0 [--renew]"
  echo ""
  echo "  Rotate the Oatmilk CA and re-sign all existing server certs."
  echo "  Preserves each server's domains, OU, email, and --forever setting."
  echo ""
  echo "  Options:"
  echo "    --renew   Keep existing server keys, only regenerate certs."
  echo "              Use this when the CA is compromised but server keys are fine."
  echo ""
  echo "  Without --renew, all server keys are regenerated too."
  echo ""
  echo "  Prompts for confirmation before doing anything."
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --renew) RENEW=true; shift ;;
    --help|-h) usage ;;
    *) echo "ERROR: Unknown option '$1'"; echo ""; usage ;;
  esac
done

# Discover existing servers before rotating
SERVERS=()
if [[ -d "$SERVERS_DIR" ]]; then
  for cnf in "$SERVERS_DIR"/*/san_server.cnf; do
    [[ -f "$cnf" ]] || continue
    SERVERS+=("$(basename "$(dirname "$cnf")")")
  done
fi

if [[ ${#SERVERS[@]} -eq 0 ]]; then
  echo "WARNING: No existing server certs found in $SERVERS_DIR/"
  echo "  Only the CA will be regenerated."
  echo ""
fi

echo "==> This will:"
echo "    1. Regenerate the CA (new key + cert)"
if [[ "$RENEW" == true ]]; then
  echo "    2. Re-sign certs for ${#SERVERS[@]} server(s): ${SERVERS[*]:-none}"
  echo "    3. Keep existing server keys"
else
  echo "    2. Re-issue certs for ${#SERVERS[@]} server(s): ${SERVERS[*]:-none}"
  echo "    3. Generate new keys for all servers"
fi
echo ""
echo "    All old certs become invalid."
echo ""
read -rp "Continue? [y/N] " confirm
if [[ "$confirm" != [yY] ]]; then
  echo "Aborted."
  exit 0
fi

echo ""

# Step 1: Rotate CA
"$SCRIPT_DIR/init-ca.sh" --force

echo ""

# Step 2: Re-issue each server cert
FAILED=()
for server in "${SERVERS[@]}"; do
  echo "================================================"
  echo "==> Re-issuing cert for: $server"
  echo "================================================"

  cnf="$SERVERS_DIR/$server/san_server.cnf"

  # Parse OU and email from existing cnf
  ou=$(grep -E '^\s*OU\s*=' "$cnf" | head -1 | sed 's/^[^=]*=\s*//')
  email=$(grep -E '^\s*emailAddress\s*=' "$cnf" | head -1 | sed 's/^[^=]*=\s*//')

  # Parse domains from [alt_names] section
  domains=()
  in_alt_names=false
  while IFS= read -r line; do
    if [[ "$line" =~ ^\[alt_names\] ]]; then
      in_alt_names=true
      continue
    fi
    if [[ "$in_alt_names" == true ]]; then
      # Stop at next section or end of file
      if [[ "$line" =~ ^\[.*\] ]]; then break; fi
      # Extract domain from "DNS.N = domain"
      if [[ "$line" =~ ^DNS\.[0-9]+[[:space:]]*=[[:space:]]*(.*) ]]; then
        domains+=("${BASH_REMATCH[1]}")
      fi
    fi
  done < "$cnf"

  if [[ ${#domains[@]} -eq 0 ]]; then
    echo "ERROR: Could not parse domains from $cnf — skipping $server"
    FAILED+=("$server")
    echo ""
    continue
  fi

  # Check original cert validity to preserve --forever if it was used
  cert_args=()
  if [[ -f "$SERVERS_DIR/$server/server.crt" ]]; then
    not_after=$(openssl x509 -in "$SERVERS_DIR/$server/server.crt" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
    if [[ -n "$not_after" ]]; then
      end_year=$(date -j -f "%b %d %T %Y %Z" "$not_after" "+%Y" 2>/dev/null || echo "")
      current_year=$(date "+%Y")
      # If cert expires more than 10 years out, it was --forever
      if [[ -n "$end_year" ]] && (( end_year - current_year > 10 )); then
        cert_args+=(--forever)
      fi
    fi
  fi

  # Build issue-cert.sh command
  cmd=("$SCRIPT_DIR/issue-cert.sh")
  if [[ "$RENEW" == true ]]; then cmd+=(--renew); fi
  if [[ -n "$ou" ]]; then cmd+=(--ou "$ou"); fi
  if [[ -n "$email" ]]; then cmd+=(--email "$email"); fi
  cmd+=("${cert_args[@]}")
  cmd+=("$server")
  cmd+=("${domains[@]}")

  if "${cmd[@]}"; then
    echo ""
  else
    echo "ERROR: Failed to re-issue cert for $server"
    FAILED+=("$server")
    echo ""
  fi
done

echo "================================================"
echo "==> Rotation complete."
echo ""
echo "    CA:      regenerated"
echo "    Servers: ${#SERVERS[@]} found, $((${#SERVERS[@]} - ${#FAILED[@]})) re-issued"

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo ""
  echo "    FAILED: ${FAILED[*]}"
  echo ""
  echo "  Re-issue failed servers manually:"
  for f in "${FAILED[@]}"; do
    echo "    $SCRIPT_DIR/issue-cert.sh $f <domain> [domains...]"
  done
  exit 1
fi

echo ""
echo "  Remember to deploy the new certs to your servers."

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CA_DIR="$BASE_DIR/oatca"

# Allow test overrides (set _TRUST_CA_* env vars before calling)
PLATFORM="${_TRUST_CA_PLATFORM:-$(uname)}"
CERT_NAME="oatmilk-ca.crt"
SUDO="${_TRUST_CA_SUDO-sudo}"

usage() {
  echo "Usage: $0 --trust | --untrust | --check"
  echo ""
  echo "  Manage trust of the Oatmilk CA in the system trust store."
  echo ""
  echo "  Supported platforms:"
  echo "    macOS          System Keychain (covers Chrome, Safari, Edge)"
  echo "    Debian/Ubuntu  /usr/local/share/ca-certificates + update-ca-certificates"
  echo "    RHEL/Fedora    /etc/pki/ca-trust/source/anchors + update-ca-trust"
  echo ""
  echo "  Actions:"
  echo "    --trust     Add CA cert to system trust store (requires sudo)"
  echo "    --untrust   Remove CA cert from system trust store (requires sudo)"
  echo "    --check     Check if CA cert is currently trusted"
  echo ""
  echo "  Firefox note:"
  echo "    Firefox uses its own NSS certificate store and ignores the"
  echo "    system trust store. To trust this CA in Firefox, go to:"
  echo "      Settings > Privacy & Security > Certificates > View Certificates"
  echo "      > Authorities > Import... > select oatca/ca.crt"
  exit 1
}

# ── Platform guard ────────────────────────────────────────────────────

if [[ "$PLATFORM" != "Darwin" && "$PLATFORM" != "Linux" ]]; then
  echo "ERROR: Unsupported platform: $PLATFORM"
  echo ""
  echo "  This script supports macOS and Linux (Debian/Ubuntu, RHEL/Fedora)."
  exit 1
fi

# ── Arg parsing ───────────────────────────────────────────────────────

ACTION=""

if [[ $# -eq 0 ]]; then
  echo "ERROR: No action specified."
  echo ""
  echo "  Usage: $0 --trust | --untrust | --check"
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --trust)   ACTION="trust";   shift ;;
    --untrust) ACTION="untrust"; shift ;;
    --check)   ACTION="check";   shift ;;
    --help|-h) usage ;;
    --*)
      echo "ERROR: Unknown option: $1"
      echo ""
      echo "  Usage: $0 --trust | --untrust | --check"
      exit 1
      ;;
    *)
      echo "ERROR: Unexpected argument: $1"
      echo ""
      echo "  Usage: $0 --trust | --untrust | --check"
      exit 1
      ;;
  esac
done

# ── CA cert existence check ──────────────────────────────────────────

if [[ ! -f "$CA_DIR/ca.crt" ]]; then
  echo "ERROR: CA certificate not found at $CA_DIR/ca.crt"
  echo ""
  echo "  Initialize the CA first:"
  echo "    Run milkman.sh → option 1 (Initialize the CA)"
  exit 1
fi

# ── Linux distro detection ───────────────────────────────────────────

TRUST_DIR=""
UPDATE_CMD=""

detect_linux_trust_store() {
  # Allow test override
  if [[ -n "${_TRUST_CA_TRUST_DIR:-}" ]]; then
    TRUST_DIR="$_TRUST_CA_TRUST_DIR"
    UPDATE_CMD="${_TRUST_CA_UPDATE_CMD:-true}"
    return
  fi
  if command -v update-ca-certificates >/dev/null 2>&1; then
    TRUST_DIR="/usr/local/share/ca-certificates"
    UPDATE_CMD="update-ca-certificates"
  elif command -v update-ca-trust >/dev/null 2>&1; then
    TRUST_DIR="/etc/pki/ca-trust/source/anchors"
    UPDATE_CMD="update-ca-trust"
  else
    echo "ERROR: Could not detect certificate trust store."
    echo ""
    echo "  Supported distros:"
    echo "    Debian/Ubuntu  (needs update-ca-certificates)"
    echo "    RHEL/Fedora    (needs update-ca-trust)"
    echo ""
    echo "  Install the ca-certificates package for your distro."
    exit 1
  fi
}

# ── Helpers ───────────────────────────────────────────────────────────

# macOS helpers
SYSTEM_KEYCHAIN="/Library/Keychains/System.keychain"

get_our_fingerprint_sha1() {
  openssl x509 -in "$CA_DIR/ca.crt" -noout -fingerprint -sha1 2>/dev/null \
    | sed 's/.*=//' | tr -d ':'
}

get_ca_cn() {
  openssl x509 -in "$CA_DIR/ca.crt" -noout -subject 2>/dev/null \
    | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p'
}

get_our_fingerprint_sha256() {
  openssl x509 -in "$CA_DIR/ca.crt" -noout -fingerprint -sha256 2>/dev/null \
    | sed 's/.*=//'
}

# Platform-aware trust check
is_trusted() {
  if [[ "$PLATFORM" == "Darwin" ]]; then
    local our_fp
    our_fp=$(get_our_fingerprint_sha1)
    local ca_cn
    ca_cn=$(get_ca_cn)

    if [[ -z "$our_fp" || -z "$ca_cn" ]]; then
      return 1
    fi

    local keychain_output
    keychain_output=$(security find-certificate -a -Z -c "$ca_cn" "$SYSTEM_KEYCHAIN" 2>/dev/null || true)

    if echo "$keychain_output" | grep -qi "$our_fp"; then
      return 0
    fi
    return 1
  else
    detect_linux_trust_store
    local installed="$TRUST_DIR/$CERT_NAME"
    if [[ ! -f "$installed" ]]; then
      return 1
    fi
    local our_fp installed_fp
    our_fp=$(get_our_fingerprint_sha256)
    installed_fp=$(openssl x509 -in "$installed" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//')
    if [[ "$our_fp" == "$installed_fp" ]]; then
      return 0
    fi
    return 1
  fi
}

store_label() {
  if [[ "$PLATFORM" == "Darwin" ]]; then
    echo "System Keychain"
  else
    echo "system trust store ($TRUST_DIR)"
  fi
}

# ── Actions ───────────────────────────────────────────────────────────

case "$ACTION" in
  check)
    local_label=$(store_label)
    echo "==> Checking trust status..."
    if is_trusted; then
      echo "    TRUSTED — CA cert is in the $local_label."
      if [[ "$PLATFORM" == "Darwin" ]]; then
        echo "    Chrome, Safari, and Edge will trust certs signed by this CA."
      else
        echo "    System applications will trust certs signed by this CA."
      fi
    else
      echo "    NOT TRUSTED — CA cert is not in the $local_label."
      echo "    Run with --trust to add it (requires sudo)."
    fi
    echo ""
    echo "    Note: Firefox uses its own certificate store."
    echo "    Import oatca/ca.crt manually via Firefox settings."
    ;;

  trust)
    local_label=$(store_label)
    if is_trusted; then
      echo "==> CA cert is already trusted in the $local_label. Nothing to do."
    else
      if [[ "$PLATFORM" == "Darwin" ]]; then
        echo "==> Adding CA cert to System Keychain (requires sudo)..."
        $SUDO security add-trusted-cert -d -r trustRoot -p ssl \
          -k "$SYSTEM_KEYCHAIN" "$CA_DIR/ca.crt"
      else
        detect_linux_trust_store
        echo "==> Copying CA cert to $TRUST_DIR/$CERT_NAME (requires sudo)..."
        $SUDO cp "$CA_DIR/ca.crt" "$TRUST_DIR/$CERT_NAME"
        echo "==> Updating trust store..."
        $SUDO $UPDATE_CMD
      fi
      echo "==> Done. System applications will now trust Oatmilk certs."
    fi
    echo ""
    echo "    Note: Firefox uses its own certificate store."
    echo "    Import oatca/ca.crt manually via Firefox settings."
    ;;

  untrust)
    local_label=$(store_label)
    if ! is_trusted; then
      echo "==> CA cert is not in the $local_label. Nothing to do."
    else
      if [[ "$PLATFORM" == "Darwin" ]]; then
        echo "==> Removing CA cert from System Keychain (requires sudo)..."
        $SUDO security remove-trusted-cert -d "$CA_DIR/ca.crt"
      else
        detect_linux_trust_store
        echo "==> Removing $TRUST_DIR/$CERT_NAME (requires sudo)..."
        $SUDO rm -f "$TRUST_DIR/$CERT_NAME"
        echo "==> Updating trust store..."
        $SUDO $UPDATE_CMD
      fi
      echo "==> Done. System applications will no longer trust Oatmilk certs."
    fi
    ;;
esac

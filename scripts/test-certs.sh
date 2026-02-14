#!/usr/bin/env bash
# No set -e — we need tests to keep running after failures
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Test in an isolated temp directory ───────────────────────────────
# Copy scripts into a temp tree so real CA/certs are never touched.

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# Mirror the directory structure the scripts expect
mkdir -p "$TEST_DIR/scripts" "$TEST_DIR/oatca" "$TEST_DIR/servers"

# Copy scripts and patch BASE_DIR to point at our temp tree
for script in init-ca.sh issue-cert.sh rotate-ca.sh trust-ca.sh; do
  cp "$SCRIPT_DIR/$script" "$TEST_DIR/scripts/$script"
  chmod +x "$TEST_DIR/scripts/$script"
done

# Copy milkman.sh for TUI integration tests
cp "$SCRIPT_DIR/../milkman.sh" "$TEST_DIR/milkman.sh"
chmod +x "$TEST_DIR/milkman.sh"

# Copy san_ca.cnf so init-ca.sh can find it
if [[ -f "$SCRIPT_DIR/../oatca/san_ca.cnf" ]]; then
  cp "$SCRIPT_DIR/../oatca/san_ca.cnf" "$TEST_DIR/oatca/san_ca.cnf"
fi

# Override SCRIPT_DIR for tests to use the temp tree
S="$TEST_DIR/scripts"
CA_DIR="$TEST_DIR/oatca"
SERVERS_DIR="$TEST_DIR/servers"

PASSED=0
FAILED=0
ERRORS=()

# ── Test helpers ─────────────────────────────────────────────────────

pass() {
  PASSED=$((PASSED + 1))
  echo "  PASS  $1"
}

fail() {
  FAILED=$((FAILED + 1))
  ERRORS+=("$1")
  echo "  FAIL  $1"
}

assert_exit() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$actual" -eq "$expected" ]]; then
    pass "$label"
  else
    fail "$label (expected exit $expected, got $actual)"
  fi
}

assert_file_exists() {
  if [[ -f "$1" ]]; then
    pass "$2"
  else
    fail "$2 ($1 not found)"
  fi
}

assert_file_missing() {
  if [[ ! -f "$1" ]]; then
    pass "$2"
  else
    fail "$2 ($1 should not exist)"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    pass "$label"
  else
    fail "$label (expected '$needle' in output)"
  fi
}

run() {
  # Run a command, capture exit code without aborting
  "$@" >/dev/null 2>&1
  return $?
}

run_output() {
  # Run a command, capture stdout+stderr
  "$@" 2>&1 || true
}

# ── Tests ────────────────────────────────────────────────────────────

echo ""
echo "=== Oatmilk CA Test Suite ==="
echo ""

echo "--- init-ca.sh ---"

# T1: Init CA from scratch
run "$S/init-ca.sh"
assert_exit 0 $? "init CA from scratch"
assert_file_exists "$CA_DIR/ca.key" "ca.key created"
assert_file_exists "$CA_DIR/ca.crt" "ca.crt created"

# T2: CA has correct extensions
ca_text=$(openssl x509 -in "$CA_DIR/ca.crt" -noout -text 2>&1 || true)
assert_contains "$ca_text" "CA:TRUE" "CA cert has basicConstraints CA:TRUE"
assert_contains "$ca_text" "Certificate Sign" "CA cert has keyCertSign"

# T3: Refuse to overwrite without --force
output=$(run_output "$S/init-ca.sh")
assert_contains "$output" "CA already exists" "overwrite error shows CA exists"
assert_contains "$output" "--force" "overwrite error suggests --force"

# T4: --force regenerates
old_serial=$(openssl x509 -in "$CA_DIR/ca.crt" -noout -serial 2>/dev/null)
run "$S/init-ca.sh" --force
new_serial=$(openssl x509 -in "$CA_DIR/ca.crt" -noout -serial 2>/dev/null)
if [[ "$old_serial" != "$new_serial" ]]; then
  pass "--force regenerates CA (new serial)"
else
  fail "--force regenerates CA (serial unchanged)"
fi

# T5: Init generates san_ca.cnf if missing
rm -f "$CA_DIR/san_ca.cnf" "$CA_DIR/ca.key" "$CA_DIR/ca.crt" "$CA_DIR/ca.srl"
run "$S/init-ca.sh"
assert_exit 0 $? "init-ca.sh generates san_ca.cnf if missing"
assert_file_exists "$CA_DIR/san_ca.cnf" "san_ca.cnf auto-generated"
assert_file_exists "$CA_DIR/ca.crt" "ca.crt created after auto-generate"

echo ""
echo "--- issue-cert.sh ---"

# T6: Issue a cert
run "$S/issue-cert.sh" test-a example.com "*.example.com"
assert_exit 0 $? "issue cert for test-a"
assert_file_exists "$SERVERS_DIR/test-a/server.key" "server.key created"
assert_file_exists "$SERVERS_DIR/test-a/server.crt" "server.crt created"
assert_file_exists "$SERVERS_DIR/test-a/server.csr" "server.csr created"
assert_file_exists "$SERVERS_DIR/test-a/san_server.cnf" "san_server.cnf created"

# T7: Cert has correct SANs
san_output=$(openssl x509 -in "$SERVERS_DIR/test-a/server.crt" -noout -ext subjectAltName 2>&1 || true)
assert_contains "$san_output" "DNS:example.com" "cert has DNS:example.com"
assert_contains "$san_output" "DNS:*.example.com" "cert has DNS:*.example.com"

# T8: Cert chain validates
openssl verify -CAfile "$CA_DIR/ca.crt" "$SERVERS_DIR/test-a/server.crt" >/dev/null 2>&1
assert_exit 0 $? "cert chain validates"

# T9: Cert has correct DN
subject=$(openssl x509 -in "$SERVERS_DIR/test-a/server.crt" -noout -subject 2>&1 || true)
assert_contains "$subject" "OU=Backoffice" "default OU is Backoffice"
assert_contains "$subject" "emailAddress=team@backoffice.oatmilk.work" "default email"

# T10: Custom --ou and --email
run "$S/issue-cert.sh" --ou Testing --email test@oatmilk.work test-b test.com
subject_b=$(openssl x509 -in "$SERVERS_DIR/test-b/server.crt" -noout -subject 2>&1 || true)
assert_contains "$subject_b" "OU=Testing" "custom --ou works"
assert_contains "$subject_b" "emailAddress=test@oatmilk.work" "custom --email works"

# T11: --forever gives long-lived cert
rm -rf "$SERVERS_DIR/test-b"
run "$S/issue-cert.sh" --forever test-b test.com
end_date=$(openssl x509 -in "$SERVERS_DIR/test-b/server.crt" -noout -enddate 2>&1 | sed 's/notAfter=//')
end_year=$(date -j -f "%b %d %T %Y %Z" "$end_date" "+%Y" 2>/dev/null || echo "0")
current_year=$(date "+%Y")
if (( end_year - current_year > 90 )); then
  pass "--forever gives 100-year cert"
else
  fail "--forever gives 100-year cert (expires $end_date)"
fi

# T12: --renew reuses existing key
old_key_hash=$(openssl rsa -in "$SERVERS_DIR/test-a/server.key" -noout -modulus 2>/dev/null | md5)
run "$S/issue-cert.sh" --renew test-a example.com "*.example.com"
new_key_hash=$(openssl rsa -in "$SERVERS_DIR/test-a/server.key" -noout -modulus 2>/dev/null | md5)
if [[ "$old_key_hash" == "$new_key_hash" ]]; then
  pass "--renew reuses existing key"
else
  fail "--renew reuses existing key (key changed)"
fi

# T13: Re-issue without --renew generates new key
old_key_hash2=$(openssl rsa -in "$SERVERS_DIR/test-a/server.key" -noout -modulus 2>/dev/null | md5)
run "$S/issue-cert.sh" test-a example.com
new_key_hash2=$(openssl rsa -in "$SERVERS_DIR/test-a/server.key" -noout -modulus 2>/dev/null | md5)
if [[ "$old_key_hash2" != "$new_key_hash2" ]]; then
  pass "re-issue generates new key"
else
  fail "re-issue generates new key (key unchanged)"
fi

echo ""
echo "--- issue-cert.sh error cases ---"

# T14: No args
output=$(run_output "$S/issue-cert.sh")
assert_contains "$output" "Missing arguments" "no args shows missing arguments"

# T15: Missing domain
output=$(run_output "$S/issue-cert.sh" myserver)
assert_contains "$output" "Missing domain" "missing domain error"

# T16: --renew on non-existent server
output=$(run_output "$S/issue-cert.sh" --renew ghost example.com)
assert_contains "$output" "no existing key" "renew non-existent server error"

# T17: Unknown flag
output=$(run_output "$S/issue-cert.sh" --bogus server example.com)
assert_contains "$output" "Unknown option" "unknown flag error"

# T18: --ou without value
output=$(run_output "$S/issue-cert.sh" --ou)
assert_contains "$output" "requires a value" "--ou without value error"

# T19: Issue cert without CA
rm -f "$CA_DIR/ca.key" "$CA_DIR/ca.crt" "$CA_DIR/ca.srl"
output=$(run_output "$S/issue-cert.sh" test-a example.com)
assert_contains "$output" "CA not found" "issue without CA error"

echo ""
echo "--- rotate-ca.sh ---"

# Rebuild CA and servers for rotation test
run "$S/init-ca.sh"
run "$S/issue-cert.sh" --forever test-a example.com "*.example.com"
run "$S/issue-cert.sh" --ou DevOps test-b internal.oatmilk.work

old_ca_serial=$(openssl x509 -in "$CA_DIR/ca.crt" -noout -serial 2>/dev/null)
old_a_serial=$(openssl x509 -in "$SERVERS_DIR/test-a/server.crt" -noout -serial 2>/dev/null)

# T20: Rotate regenerates everything
echo "y" | "$S/rotate-ca.sh" >/dev/null 2>&1
assert_exit 0 $? "rotate completes successfully"

new_ca_serial=$(openssl x509 -in "$CA_DIR/ca.crt" -noout -serial 2>/dev/null)
new_a_serial=$(openssl x509 -in "$SERVERS_DIR/test-a/server.crt" -noout -serial 2>/dev/null)

if [[ "$old_ca_serial" != "$new_ca_serial" ]]; then
  pass "rotate regenerates CA"
else
  fail "rotate regenerates CA (serial unchanged)"
fi

if [[ "$old_a_serial" != "$new_a_serial" ]]; then
  pass "rotate re-issues server certs"
else
  fail "rotate re-issues server certs (serial unchanged)"
fi

# T21: Rotated certs still validate
openssl verify -CAfile "$CA_DIR/ca.crt" "$SERVERS_DIR/test-a/server.crt" >/dev/null 2>&1
assert_exit 0 $? "test-a validates after rotate"
openssl verify -CAfile "$CA_DIR/ca.crt" "$SERVERS_DIR/test-b/server.crt" >/dev/null 2>&1
assert_exit 0 $? "test-b validates after rotate"

# T22: Rotate preserves --forever
end_date=$(openssl x509 -in "$SERVERS_DIR/test-a/server.crt" -noout -enddate 2>&1 | sed 's/notAfter=//')
end_year=$(date -j -f "%b %d %T %Y %Z" "$end_date" "+%Y" 2>/dev/null || echo "0")
if (( end_year - current_year > 90 )); then
  pass "rotate preserves --forever on test-a"
else
  fail "rotate preserves --forever on test-a (expires $end_date)"
fi

# T23: Rotate preserves custom OU
subject_b=$(openssl x509 -in "$SERVERS_DIR/test-b/server.crt" -noout -subject 2>&1 || true)
assert_contains "$subject_b" "OU=DevOps" "rotate preserves custom OU on test-b"

# T24: Decline rotation
old_ca_serial2=$(openssl x509 -in "$CA_DIR/ca.crt" -noout -serial 2>/dev/null)
echo "n" | "$S/rotate-ca.sh" >/dev/null 2>&1
new_ca_serial2=$(openssl x509 -in "$CA_DIR/ca.crt" -noout -serial 2>/dev/null)
if [[ "$old_ca_serial2" == "$new_ca_serial2" ]]; then
  pass "declining rotation changes nothing"
else
  fail "declining rotation changes nothing (CA serial changed)"
fi

echo ""
echo "--- trust-ca.sh ---"

# T25: No args
output=$(run_output "$S/trust-ca.sh")
assert_contains "$output" "No action specified" "no args shows 'No action specified'"

# T26: Unknown flag
output=$(run_output "$S/trust-ca.sh" --bogus)
assert_contains "$output" "Unknown option" "unknown flag shows error"

# T27: Positional arg
output=$(run_output "$S/trust-ca.sh" something)
assert_contains "$output" "Unexpected argument" "positional arg shows error"

# T28: --trust without CA cert
rm -f "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$CA_DIR/ca.srl"
output=$(run_output "$S/trust-ca.sh" --trust)
assert_contains "$output" "CA certificate not found" "--trust without CA cert shows error"
assert_contains "$output" "option 1" "--trust without CA suggests init"

# T29: --untrust without CA cert
output=$(run_output "$S/trust-ca.sh" --untrust)
assert_contains "$output" "CA certificate not found" "--untrust without CA cert shows error"

# T30: --check without CA cert
output=$(run_output "$S/trust-ca.sh" --check)
assert_contains "$output" "CA certificate not found" "--check without CA cert shows error"

# T31: --help shows usage with all flags and Firefox mention
output=$(run_output "$S/trust-ca.sh" --help)
assert_contains "$output" "--trust" "--help mentions --trust"
assert_contains "$output" "--untrust" "--help mentions --untrust"
assert_contains "$output" "--check" "--help mentions --check"
assert_contains "$output" "Firefox" "--help mentions Firefox"
assert_contains "$output" "Debian" "--help mentions Debian/Ubuntu"
assert_contains "$output" "RHEL" "--help mentions RHEL/Fedora"

# Rebuild CA for remaining tests
run "$S/init-ca.sh"

# T32: --check on temp CA shows NOT TRUSTED (never added to real keychain)
output=$(run_output "$S/trust-ca.sh" --check)
assert_contains "$output" "NOT TRUSTED" "--check on temp CA shows NOT TRUSTED"

# T33: --check exits cleanly (exit code 0)
"$S/trust-ca.sh" --check >/dev/null 2>&1
assert_exit 0 $? "--check exits cleanly"

# T34: milkman option 8 shows trust sub-menu
output=$(echo "8" | "$TEST_DIR/milkman.sh" 2>&1 || true)
assert_contains "$output" "Trust / Untrust CA" "milkman option 8 shows trust sub-menu"

echo ""
echo "--- trust-ca.sh full cycle (mocked Linux path) ---"

# Set up a fake trust store dir so we can test trust/untrust/check without sudo
FAKE_TRUST_DIR="$TEST_DIR/fake-trust-store"
mkdir -p "$FAKE_TRUST_DIR"

# T35: --check shows NOT TRUSTED on mocked Linux (cert not in fake trust dir)
output=$(
  _TRUST_CA_PLATFORM=Linux \
  _TRUST_CA_TRUST_DIR="$FAKE_TRUST_DIR" \
  _TRUST_CA_UPDATE_CMD=true \
  _TRUST_CA_SUDO="" \
  run_output "$S/trust-ca.sh" --check
)
assert_contains "$output" "NOT TRUSTED" "mocked Linux --check shows NOT TRUSTED"

# T36: --trust copies cert to fake trust dir
output=$(
  _TRUST_CA_PLATFORM=Linux \
  _TRUST_CA_TRUST_DIR="$FAKE_TRUST_DIR" \
  _TRUST_CA_UPDATE_CMD=true \
  _TRUST_CA_SUDO="" \
  run_output "$S/trust-ca.sh" --trust
)
assert_contains "$output" "Done" "--trust succeeds on mocked Linux"
assert_file_exists "$FAKE_TRUST_DIR/oatmilk-ca.crt" "--trust copies cert to trust dir"

# T37: --check shows TRUSTED after trust
output=$(
  _TRUST_CA_PLATFORM=Linux \
  _TRUST_CA_TRUST_DIR="$FAKE_TRUST_DIR" \
  _TRUST_CA_UPDATE_CMD=true \
  _TRUST_CA_SUDO="" \
  run_output "$S/trust-ca.sh" --check
)
assert_contains "$output" "TRUSTED" "mocked Linux --check shows TRUSTED after trust"
# Make sure it's not "NOT TRUSTED"
if echo "$output" | grep -q "NOT TRUSTED"; then
  fail "mocked Linux --check should not say NOT TRUSTED after trust"
else
  pass "mocked Linux --check does not say NOT TRUSTED"
fi

# T38: --trust is idempotent (already trusted)
output=$(
  _TRUST_CA_PLATFORM=Linux \
  _TRUST_CA_TRUST_DIR="$FAKE_TRUST_DIR" \
  _TRUST_CA_UPDATE_CMD=true \
  _TRUST_CA_SUDO="" \
  run_output "$S/trust-ca.sh" --trust
)
assert_contains "$output" "already trusted" "--trust is idempotent"

# T39: --untrust removes cert from fake trust dir
output=$(
  _TRUST_CA_PLATFORM=Linux \
  _TRUST_CA_TRUST_DIR="$FAKE_TRUST_DIR" \
  _TRUST_CA_UPDATE_CMD=true \
  _TRUST_CA_SUDO="" \
  run_output "$S/trust-ca.sh" --untrust
)
assert_contains "$output" "Done" "--untrust succeeds on mocked Linux"
assert_file_missing "$FAKE_TRUST_DIR/oatmilk-ca.crt" "--untrust removes cert from trust dir"

# T40: --check shows NOT TRUSTED after untrust
output=$(
  _TRUST_CA_PLATFORM=Linux \
  _TRUST_CA_TRUST_DIR="$FAKE_TRUST_DIR" \
  _TRUST_CA_UPDATE_CMD=true \
  _TRUST_CA_SUDO="" \
  run_output "$S/trust-ca.sh" --check
)
assert_contains "$output" "NOT TRUSTED" "mocked Linux --check shows NOT TRUSTED after untrust"

# T41: --untrust is idempotent (already untrusted)
output=$(
  _TRUST_CA_PLATFORM=Linux \
  _TRUST_CA_TRUST_DIR="$FAKE_TRUST_DIR" \
  _TRUST_CA_UPDATE_CMD=true \
  _TRUST_CA_SUDO="" \
  run_output "$S/trust-ca.sh" --untrust
)
assert_contains "$output" "Nothing to do" "--untrust is idempotent"

# T42: --check detects stale cert (different fingerprint after CA rotation)
# Trust the current CA
_TRUST_CA_PLATFORM=Linux \
_TRUST_CA_TRUST_DIR="$FAKE_TRUST_DIR" \
_TRUST_CA_UPDATE_CMD=true \
_TRUST_CA_SUDO="" \
"$S/trust-ca.sh" --trust >/dev/null 2>&1

# Rotate CA (new fingerprint)
run "$S/init-ca.sh" --force

# Check should show NOT TRUSTED (old cert in trust dir doesn't match new CA)
output=$(
  _TRUST_CA_PLATFORM=Linux \
  _TRUST_CA_TRUST_DIR="$FAKE_TRUST_DIR" \
  _TRUST_CA_UPDATE_CMD=true \
  _TRUST_CA_SUDO="" \
  run_output "$S/trust-ca.sh" --check
)
assert_contains "$output" "NOT TRUSTED" "stale cert detected after CA rotation"

# Clean up fake trust store
rm -rf "$FAKE_TRUST_DIR"

# ── Summary ──────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASSED passed, $FAILED failed ==="

if [[ $FAILED -gt 0 ]]; then
  echo ""
  echo "Failures:"
  for e in "${ERRORS[@]}"; do
    echo "  - $e"
  done
  exit 1
fi

echo ""

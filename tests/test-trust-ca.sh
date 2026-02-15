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

# T34: milkman option 4 shows trust sub-menu
output=$(echo "4" | "$TEST_DIR/milkman.sh" 2>&1 || true)
assert_contains "$output" "Trust / Untrust CA" "milkman option 4 shows trust sub-menu"

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

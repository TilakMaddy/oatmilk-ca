#!/usr/bin/env bash
# No set -e — we need tests to keep running after failures
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$ROOT_DIR/tests"

# ── Test in an isolated temp directory ───────────────────────────────
# Copy scripts into a temp tree so real CA/certs are never touched.

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# Mirror the directory structure the scripts expect
mkdir -p "$TEST_DIR/scripts" "$TEST_DIR/oatca" "$TEST_DIR/servers" "$TEST_DIR/remotes"

# Copy scripts
for script in init-ca.sh issue-cert.sh rotate-ca.sh trust-ca.sh remote-sync.sh; do
  cp "$ROOT_DIR/scripts/$script" "$TEST_DIR/scripts/$script"
  chmod +x "$TEST_DIR/scripts/$script"
done

# Copy milkman.sh for TUI integration tests
cp "$ROOT_DIR/milkman.sh" "$TEST_DIR/milkman.sh"
chmod +x "$TEST_DIR/milkman.sh"

# Copy san_ca.cnf so init-ca.sh can find it
if [[ -f "$ROOT_DIR/oatca/san_ca.cnf" ]]; then
  cp "$ROOT_DIR/oatca/san_ca.cnf" "$TEST_DIR/oatca/san_ca.cnf"
fi

# Override paths for tests to use the temp tree
S="$TEST_DIR/scripts"
CA_DIR="$TEST_DIR/oatca"
SERVERS_DIR="$TEST_DIR/servers"

# Source shared helpers (pass, fail, assert_*, run, run_output)
source "$TESTS_DIR/helpers.sh"

# ── Run tests ────────────────────────────────────────────────────────

echo ""
echo "=== Oatmilk CA Test Suite ==="
echo ""

# Run individual test files or all if no args given
if [[ $# -gt 0 ]]; then
  for arg in "$@"; do
    test_file="$TESTS_DIR/$arg"
    if [[ ! -f "$test_file" ]]; then
      test_file="$TESTS_DIR/test-$arg.sh"
    fi
    if [[ -f "$test_file" ]]; then
      source "$test_file"
    else
      echo "ERROR: Test file not found: $arg"
      exit 1
    fi
  done
else
  for test_file in "$TESTS_DIR"/test-*.sh; do
    [[ -f "$test_file" ]] || continue
    source "$test_file"
  done
fi

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

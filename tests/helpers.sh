#!/usr/bin/env bash
# Shared test helpers — sourced by each test file and the runner.
# Expects TEST_DIR, S, CA_DIR, SERVERS_DIR to be set by the runner.

PASSED=0
FAILED=0
ERRORS=()

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

echo ""
echo "--- remote-sync.sh ---"

# Rebuild CA and a server for sync tests
rm -f "$CA_DIR/ca.key" "$CA_DIR/ca.crt" "$CA_DIR/ca.srl"
run "$S/init-ca.sh"
rm -rf "$SERVERS_DIR/test-a" "$SERVERS_DIR/test-b"
run "$S/issue-cert.sh" test-a example.com
run "$S/issue-cert.sh" test-b internal.oatmilk.work

# Clean remotes dir
rm -rf "$TEST_DIR/remotes"/*

# Create mock ssh/scp scripts that do local file copies
MOCK_BIN="$TEST_DIR/mock-bin"
mkdir -p "$MOCK_BIN"

FAKE_REMOTE="$TEST_DIR/fake-remote"
mkdir -p "$FAKE_REMOTE"

# Mock SSH: parse "user@host" and execute commands with path substitution
# Uses unquoted heredoc so $FAKE_REMOTE is embedded at creation time
# NOTE: uses sed for path substitution because bash ${var//} uses / as delimiter
cat > "$MOCK_BIN/mock-ssh" <<MOCK_SSH
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o|-p|-i) shift 2 ;;
    *@*) shift; break ;;
    *) shift ;;
  esac
done
cmd="\$*"
cmd=\$(echo "\$cmd" | sed "s|/etc/oatmilk|$FAKE_REMOTE|g")
eval "\$cmd"
MOCK_SSH
chmod +x "$MOCK_BIN/mock-ssh"

# Mock SSH that always fails (simulates unreachable host)
cat > "$MOCK_BIN/mock-ssh-fail" <<'MOCK_SSH_FAIL'
#!/usr/bin/env bash
exit 255
MOCK_SSH_FAIL
chmod +x "$MOCK_BIN/mock-ssh-fail"

# Mock SCP: parse "src user@host:dest" and do a local copy
cat > "$MOCK_BIN/mock-scp" <<MOCK_SCP
#!/usr/bin/env bash
SRC=""
DEST=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o|-P|-i) shift 2 ;;
    *)
      if [[ -z "\$SRC" ]]; then
        SRC="\$1"
      else
        DEST="\$1"
      fi
      shift
      ;;
  esac
done
REMOTE_PATH="\${DEST#*:}"
LOCAL_DEST=\$(echo "\$REMOTE_PATH" | sed "s|/etc/oatmilk|$FAKE_REMOTE|g")
cp "\$SRC" "\$LOCAL_DEST"
MOCK_SCP
chmod +x "$MOCK_BIN/mock-scp"

# T43: --add creates remote.conf
output=$(run_output "$S/remote-sync.sh" --add prod --host root@192.168.1.10)
assert_file_exists "$TEST_DIR/remotes/prod/remote.conf" "--add creates remote.conf"

# T44: remote.conf contains correct HOST
conf_content=$(cat "$TEST_DIR/remotes/prod/remote.conf")
assert_contains "$conf_content" "HOST=root@192.168.1.10" "remote.conf contains correct HOST"

# T45: --add with custom port and key
run "$S/remote-sync.sh" --add staging --host deploy@10.0.0.5 --port 2222 --key /tmp/id_staging
conf_staging=$(cat "$TEST_DIR/remotes/staging/remote.conf")
assert_contains "$conf_staging" "PORT=2222" "--add stores custom port"
assert_contains "$conf_staging" "KEY=/tmp/id_staging" "--add stores custom key"

# T46: --add defaults PORT=22, KEY=
assert_contains "$conf_content" "PORT=22" "--add defaults PORT=22"
assert_contains "$conf_content" "KEY=" "--add defaults KEY= (empty)"

# T47: --add without --host fails
output=$(run_output "$S/remote-sync.sh" --add nohost)
assert_contains "$output" "--host is required" "--add without --host fails"

# T48: --add with empty name fails
output=$(run_output "$S/remote-sync.sh" --add "" --host root@host)
assert_contains "$output" "empty" "--add with empty name fails"

# T49: --list shows registered remotes
output=$(
  _REMOTE_SYNC_SSH_CMD="$MOCK_BIN/mock-ssh" \
  run_output "$S/remote-sync.sh" --list
)
assert_contains "$output" "prod" "--list shows 'prod'"
assert_contains "$output" "staging" "--list shows 'staging'"

# T49b: --list always shows Key line (default when empty)
assert_contains "$output" "Key:   (default)" "--list shows Key: (default) when no key set"

# T49c: --list shows Key path when key is configured
assert_contains "$output" "Key:   /tmp/id_staging" "--list shows key path for staging"

# T49d: --list shows Remote status for never-synced remotes (no certs on remote)
assert_contains "$output" "Remote:" "--list shows Remote: status line"

# T50: --list with no remotes shows message
rm -rf "$TEST_DIR/remotes"/*
output=$(run_output "$S/remote-sync.sh" --list)
assert_contains "$output" "No remotes registered" "--list with no remotes shows message"

# Re-add for remaining tests
run "$S/remote-sync.sh" --add prod --host root@192.168.1.10

# T51: --remove deletes remote directory
run "$S/remote-sync.sh" --add temp-remote --host user@host
run "$S/remote-sync.sh" --remove temp-remote
if [[ ! -d "$TEST_DIR/remotes/temp-remote" ]]; then
  pass "--remove deletes remote directory"
else
  fail "--remove deletes remote directory (dir still exists)"
fi

# T52: --remove non-existent remote fails
output=$(run_output "$S/remote-sync.sh" --remove ghost)
assert_contains "$output" "not found" "--remove non-existent remote fails"

# T53: --sync copies CA cert (mocked SSH/SCP)
rm -rf "$FAKE_REMOTE"/*
output=$(
  _REMOTE_SYNC_SSH_CMD="$MOCK_BIN/mock-ssh" \
  _REMOTE_SYNC_SCP_CMD="$MOCK_BIN/mock-scp" \
  run_output "$S/remote-sync.sh" --sync prod
)
assert_file_exists "$FAKE_REMOTE/certs/ca.crt" "--sync copies CA cert"

# T54: --sync copies server certs (mocked)
assert_file_exists "$FAKE_REMOTE/certs/test-a/server.crt" "--sync copies test-a server.crt"
assert_file_exists "$FAKE_REMOTE/certs/test-a/server.key" "--sync copies test-a server.key"
assert_file_exists "$FAKE_REMOTE/certs/test-b/server.crt" "--sync copies test-b server.crt"

# T55: --sync records last-sync.conf
assert_file_exists "$TEST_DIR/remotes/prod/last-sync.conf" "--sync creates last-sync.conf"

# T56: last-sync.conf contains synced servers and hash
sync_content=$(cat "$TEST_DIR/remotes/prod/last-sync.conf")
assert_contains "$sync_content" "test-a" "last-sync.conf records test-a"
assert_contains "$sync_content" "test-b" "last-sync.conf records test-b"
assert_contains "$sync_content" "SYNC_TIME=" "last-sync.conf records timestamp"
assert_contains "$sync_content" "SYNC_HASH=" "last-sync.conf records content hash"

# T57: --list shows synced status (certs unchanged since sync)
output=$(
  _REMOTE_SYNC_SSH_CMD="$MOCK_BIN/mock-ssh" \
  run_output "$S/remote-sync.sh" --list
)
assert_contains "$output" "synced" "--list shows synced status"
assert_contains "$output" "Host:" "--list shows host"
assert_contains "$output" "test-a" "--list shows synced server test-a"
assert_contains "$output" "test-b" "--list shows synced server test-b"

# T57b: --list shows Remote: verified after sync (mock SSH can reach fake remote)
assert_contains "$output" "Remote:  verified" "--list shows Remote: verified after sync"

# T58: --list shows stale after cert change
run "$S/issue-cert.sh" test-c stale.example.com
output=$(
  _REMOTE_SYNC_SSH_CMD="$MOCK_BIN/mock-ssh" \
  run_output "$S/remote-sync.sh" --list
)
assert_contains "$output" "stale" "--list shows stale after new cert issued"

# T58b: --list shows Remote: out of sync when certs differ
assert_contains "$output" "Remote:  out of sync" "--list shows Remote: out of sync after new cert"
rm -rf "$SERVERS_DIR/test-c"

# T59: --sync without CA fails
rm -f "$CA_DIR/ca.crt" "$CA_DIR/ca.key" "$CA_DIR/ca.srl"
output=$(run_output "$S/remote-sync.sh" --sync prod)
assert_contains "$output" "CA not initialized" "--sync without CA fails"

# Rebuild CA for remaining tests
run "$S/init-ca.sh"

# T60: --sync non-existent remote fails
output=$(run_output "$S/remote-sync.sh" --sync ghost)
assert_contains "$output" "not found" "--sync non-existent remote fails"

# T61: No action shows error
output=$(run_output "$S/remote-sync.sh")
assert_contains "$output" "No action specified" "no action shows error"

# T62: Unknown flag shows error
output=$(run_output "$S/remote-sync.sh" --bogus)
assert_contains "$output" "Unknown option" "unknown flag shows error"

# T63: --add duplicate name fails
output=$(run_output "$S/remote-sync.sh" --add prod --host root@other)
assert_contains "$output" "already exists" "--add duplicate name fails"

# T64: --add invalid name fails
output=$(run_output "$S/remote-sync.sh" --add "bad name!" --host root@host)
assert_contains "$output" "Invalid remote name" "--add invalid name fails"

# T65: --list shows Remote: unreachable when SSH fails
output=$(
  _REMOTE_SYNC_SSH_CMD="$MOCK_BIN/mock-ssh-fail" \
  run_output "$S/remote-sync.sh" --list
)
assert_contains "$output" "Remote:  unreachable" "--list shows Remote: unreachable when SSH fails"

# T66: --list shows Remote: no certs on remote when remote is empty
# Re-sync first to populate last-sync.conf, then wipe fake remote certs
rm -rf "$FAKE_REMOTE"/*
output=$(
  _REMOTE_SYNC_SSH_CMD="$MOCK_BIN/mock-ssh" \
  _REMOTE_SYNC_SCP_CMD="$MOCK_BIN/mock-scp" \
  run_output "$S/remote-sync.sh" --sync prod
)
rm -rf "$FAKE_REMOTE/certs"
mkdir -p "$FAKE_REMOTE"
output=$(
  _REMOTE_SYNC_SSH_CMD="$MOCK_BIN/mock-ssh" \
  run_output "$S/remote-sync.sh" --list
)
assert_contains "$output" "Remote:  no certs on remote" "--list shows Remote: no certs on remote"

# Clean up
rm -rf "$FAKE_REMOTE" "$MOCK_BIN"

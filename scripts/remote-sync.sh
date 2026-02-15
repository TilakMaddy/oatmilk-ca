#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CA_DIR="$BASE_DIR/oatca"
SERVERS_DIR="$BASE_DIR/servers"
REMOTES_DIR="$BASE_DIR/remotes"

# Allow test overrides for SSH/SCP commands
SSH_CMD="${_REMOTE_SYNC_SSH_CMD:-ssh}"

REMOTE_CERT_DIR="/etc/oatmilk/certs"

# ── Helpers ──────────────────────────────────────────────────────────

die() {
  echo "ERROR: $1"
  exit 1
}

validate_name() {
  local name="$1"
  if [[ -z "$name" ]]; then
    die "Remote name cannot be empty."
  fi
  if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    die "Invalid remote name '$name'. Use only letters, numbers, hyphens, and underscores."
  fi
}

compute_current_hash() {
  # Hash of CA cert + all server certs/keys (sorted for consistency)
  [[ -f "$CA_DIR/ca.crt" ]] || return 1
  local servers=()
  for crt in "$SERVERS_DIR"/*/server.crt; do
    [[ -f "$crt" ]] || continue
    servers+=("$(basename "$(dirname "$crt")")")
  done
  {
    cat "$CA_DIR/ca.crt"
    for sname in $(printf '%s\n' "${servers[@]}" | sort); do
      cat "$SERVERS_DIR/$sname/server.crt" "$SERVERS_DIR/$sname/server.key"
    done
  } | shasum -a 256 | cut -d' ' -f1
}

load_remote() {
  local name="$1"
  local conf="$REMOTES_DIR/$name/remote.conf"
  if [[ ! -f "$conf" ]]; then
    die "Remote '$name' not found."
  fi
  # shellcheck disable=SC1090
  source "$conf"
}

build_ssh_opts() {
  local opts=()
  opts+=(-o "StrictHostKeyChecking=accept-new")
  opts+=(-o "ConnectTimeout=10")
  if [[ -n "${PORT:-}" && "$PORT" != "22" ]]; then
    opts+=(-p "$PORT")
  fi
  if [[ -n "${KEY:-}" ]]; then
    opts+=(-i "$KEY")
  fi
  echo "${opts[@]}"
}

# ── Subcommands ──────────────────────────────────────────────────────

do_add() {
  local name="" host="" port="22" key=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host)
        [[ $# -ge 2 ]] || die "--host requires a value."
        host="$2"; shift 2 ;;
      --port)
        [[ $# -ge 2 ]] || die "--port requires a value."
        port="$2"; shift 2 ;;
      --key)
        [[ $# -ge 2 ]] || die "--key requires a value."
        key="$2"; shift 2 ;;
      *)
        if [[ -z "$name" ]]; then
          name="$1"; shift
        else
          die "Unexpected argument: $1"
        fi
        ;;
    esac
  done

  validate_name "$name"

  if [[ -z "$host" ]]; then
    die "--host is required."
  fi

  if [[ -d "$REMOTES_DIR/$name" ]]; then
    die "Remote '$name' already exists."
  fi

  mkdir -p "$REMOTES_DIR/$name"
  cat > "$REMOTES_DIR/$name/remote.conf" <<EOF
HOST=$host
PORT=$port
KEY=$key
EOF

  echo "==> Remote '$name' added ($host:$port)."
}

do_remove() {
  local name="$1"
  validate_name "$name"

  if [[ ! -d "$REMOTES_DIR/$name" ]]; then
    die "Remote '$name' not found."
  fi

  rm -rf "$REMOTES_DIR/$name"
  echo "==> Remote '$name' removed."
}

verify_remote_hash() {
  local host="$1"
  local ssh_opts
  ssh_opts=$(build_ssh_opts)

  # SSH into the remote and compute hash of cert files (sorted for consistency)
  # Uses sudo since cert dir is typically root-owned (/etc/oatmilk)
  # shellcheck disable=SC2086
  $SSH_CMD $ssh_opts "$host" "
    if ! sudo test -f '$REMOTE_CERT_DIR/ca.crt'; then
      echo 'NO_CERTS'
      exit 0
    fi
    {
      sudo cat '$REMOTE_CERT_DIR/ca.crt'
      for sname in \$(sudo ls -1 '$REMOTE_CERT_DIR' | sort); do
        if sudo test -f '$REMOTE_CERT_DIR/'\"\$sname\"'/server.crt' && sudo test -f '$REMOTE_CERT_DIR/'\"\$sname\"'/server.key'; then
          sudo cat '$REMOTE_CERT_DIR/'\"\$sname\"'/server.crt' '$REMOTE_CERT_DIR/'\"\$sname\"'/server.key'
        fi
      done
    } | shasum -a 256 | cut -d' ' -f1
  " 2>/dev/null
}

do_list() {
  local count=0
  local current_hash
  current_hash=$(compute_current_hash 2>/dev/null) || current_hash=""

  if [[ -d "$REMOTES_DIR" ]]; then
    for conf in "$REMOTES_DIR"/*/remote.conf; do
      [[ -f "$conf" ]] || continue
      local name
      name=$(basename "$(dirname "$conf")")
      # shellcheck disable=SC1090
      source "$conf"

      if [[ $count -gt 0 ]]; then echo ""; fi

      local sync_conf="$REMOTES_DIR/$name/last-sync.conf"
      local status_label="never synced"
      local remote_status=""

      if [[ -f "$sync_conf" ]]; then
        local SYNC_TIME="" SYNC_SERVERS="" SYNC_HASH=""
        # shellcheck disable=SC1090
        source "$sync_conf"
        if [[ -n "$current_hash" && "$SYNC_HASH" == "$current_hash" ]]; then
          status_label="synced"
        else
          status_label="stale"
        fi
      fi

      # Verify remote is reachable and files match
      local remote_hash
      remote_hash=$(verify_remote_hash "$HOST" 2>/dev/null) || remote_hash=""

      if [[ -z "$remote_hash" ]]; then
        remote_status="unreachable"
      elif [[ "$remote_hash" == "NO_CERTS" ]]; then
        remote_status="no certs on remote"
      elif [[ -n "$current_hash" && "$remote_hash" == "$current_hash" ]]; then
        remote_status="verified"
      else
        remote_status="out of sync"
      fi

      echo "  $name  ($status_label)"
      echo "    Host:  ${HOST}:${PORT}"
      if [[ -n "${KEY:-}" ]]; then
        echo "    Key:   $KEY"
      else
        echo "    Key:   (default)"
      fi
      echo "    Remote:  $remote_status"

      if [[ -f "$sync_conf" ]]; then
        echo "    Last sync:  $SYNC_TIME"
        if [[ -n "$SYNC_SERVERS" ]]; then
          echo "    Servers:"
          for sname in $SYNC_SERVERS; do
            echo "      - $sname"
          done
        else
          echo "    Servers:  (CA only, no server certs)"
        fi
      fi

      count=$((count + 1))
    done
  fi
  if [[ $count -eq 0 ]]; then
    echo "  No remotes registered."
  fi
}

do_sync() {
  local name="$1"
  validate_name "$name"
  load_remote "$name"

  # Validate CA exists
  if [[ ! -f "$CA_DIR/ca.crt" ]]; then
    die "CA not initialized. Run milkman.sh → option 1 first."
  fi

  # Collect servers
  local server_names=()
  if [[ -d "$SERVERS_DIR" ]]; then
    for crt in "$SERVERS_DIR"/*/server.crt; do
      [[ -f "$crt" ]] || continue
      server_names+=("$(basename "$(dirname "$crt")")")
    done
  fi

  # Build SSH/SCP options
  local ssh_opts
  ssh_opts=$(build_ssh_opts)

  echo "==> Syncing to '$name' ($HOST)..."

  # Create remote directories (sudo for /etc paths)
  local dirs=("$REMOTE_CERT_DIR")
  for sname in "${server_names[@]}"; do
    dirs+=("$REMOTE_CERT_DIR/$sname")
  done

  # shellcheck disable=SC2086
  $SSH_CMD $ssh_opts "$HOST" "sudo mkdir -p ${dirs[*]}"

  # Copy CA cert via ssh+sudo tee (scp can't write to root-owned paths)
  # shellcheck disable=SC2086
  cat "$CA_DIR/ca.crt" | $SSH_CMD $ssh_opts "$HOST" "sudo tee $REMOTE_CERT_DIR/ca.crt > /dev/null"
  echo "    CA cert → $REMOTE_CERT_DIR/ca.crt"

  # Copy server certs
  for sname in "${server_names[@]}"; do
    # shellcheck disable=SC2086
    cat "$SERVERS_DIR/$sname/server.crt" | $SSH_CMD $ssh_opts "$HOST" "sudo tee $REMOTE_CERT_DIR/$sname/server.crt > /dev/null"
    # shellcheck disable=SC2086
    cat "$SERVERS_DIR/$sname/server.key" | $SSH_CMD $ssh_opts "$HOST" "sudo tee $REMOTE_CERT_DIR/$sname/server.key > /dev/null && sudo chmod 600 $REMOTE_CERT_DIR/$sname/server.key"
    echo "    $sname → $REMOTE_CERT_DIR/$sname/"
  done

  # Compute content hash of everything that was synced
  local sync_hash
  sync_hash=$( {
    cat "$CA_DIR/ca.crt"
    for sname in $(printf '%s\n' "${server_names[@]}" | sort); do
      cat "$SERVERS_DIR/$sname/server.crt" "$SERVERS_DIR/$sname/server.key"
    done
  } | shasum -a 256 | cut -d' ' -f1 )

  # Record sync status
  cat > "$REMOTES_DIR/$name/last-sync.conf" <<SYNCEOF
SYNC_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
SYNC_SERVERS="${server_names[*]}"
SYNC_HASH="$sync_hash"
SYNCEOF

  echo "==> Sync complete. ${#server_names[@]} server(s) + CA cert pushed to $HOST."
}

do_sync_all() {
  local count=0
  if [[ -d "$REMOTES_DIR" ]]; then
    for conf in "$REMOTES_DIR"/*/remote.conf; do
      [[ -f "$conf" ]] || continue
      local name
      name=$(basename "$(dirname "$conf")")
      do_sync "$name"
      count=$((count + 1))
    done
  fi
  if [[ $count -eq 0 ]]; then
    echo "  No remotes registered."
  else
    echo "==> All $count remote(s) synced."
  fi
}

# ── Arg parsing ──────────────────────────────────────────────────────

if [[ $# -eq 0 ]]; then
  die "No action specified. Use --add, --remove, --list, --sync, or --sync-all."
fi

ACTION=""
case "$1" in
  --add)      ACTION="add";      shift ;;
  --remove)   ACTION="remove";   shift ;;
  --list)     ACTION="list";     shift ;;
  --sync)     ACTION="sync";     shift ;;
  --sync-all) ACTION="sync_all"; shift ;;
  *)
    die "Unknown option: $1. Use --add, --remove, --list, --sync, or --sync-all."
    ;;
esac

case "$ACTION" in
  add)      do_add "$@" ;;
  remove)
    [[ $# -ge 1 ]] || die "--remove requires a remote name."
    do_remove "$1"
    ;;
  list)     do_list ;;
  sync)
    [[ $# -ge 1 ]] || die "--sync requires a remote name."
    do_sync "$1"
    ;;
  sync_all) do_sync_all ;;
esac

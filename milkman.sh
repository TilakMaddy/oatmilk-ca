#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$BASE_DIR/scripts"
CA_DIR="$BASE_DIR/oatca"
SERVERS_DIR="$BASE_DIR/servers"
REMOTES_DIR="$BASE_DIR/remotes"

BOLD="\033[1m"
DIM="\033[2m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

# ── Error wrapper ────────────────────────────────────────────────────
# Runs a script, catches failures, and prints milkman-friendly recovery

run_script() {
  local script="$1"
  shift

  if "$SCRIPTS_DIR/$script" "$@"; then
    return 0
  fi

  local rc=$?
  echo ""
  echo -e "  ${RED}Something went wrong.${RESET} Here's what to try in milkman:"
  echo ""

  case "$script" in
    init-ca.sh)
      echo -e "  ${BOLD}1${RESET}  Initialize the CA          (if CA doesn't exist)"
      echo -e "  ${BOLD}2 → 4${RESET}  Rotate CA + all certs  (if CA exists and you want to regenerate)"
      ;;
    issue-cert.sh)
      if [[ ! -f "$CA_DIR/ca.crt" || ! -f "$CA_DIR/ca.key" ]]; then
        echo -e "  ${BOLD}1${RESET}  Initialize the CA first, then try again"
      else
        echo -e "  ${BOLD}2 → 1${RESET}  Issue a new server cert  (fresh key + cert)"
        echo -e "  ${BOLD}2 → 2${RESET}  Renew a server cert      (keep existing key)"
      fi
      ;;
    rotate-ca.sh)
      echo -e "  ${BOLD}1${RESET}  Initialize the CA          (if starting fresh)"
      echo -e "  ${BOLD}2 → 4${RESET}  Rotate again             (if it was interrupted)"
      ;;
    trust-ca.sh)
      echo -e "  ${BOLD}4${RESET}  Trust / Untrust CA         (try again)"
      echo -e "  ${BOLD}1${RESET}  Initialize the CA          (if CA doesn't exist)"
      ;;
    remote-sync.sh)
      echo -e "  ${BOLD}5${RESET}  Remote sync                (try again)"
      echo -e "  ${BOLD}1${RESET}  Initialize the CA          (if CA doesn't exist)"
      ;;
  esac

  echo ""
  return $rc
}

# ── Helpers ──────────────────────────────────────────────────────────

print_header() {
  clear
  echo ""
  echo -e "${BOLD}  Oatmilk CA${RESET}  ${DIM}certificate management${RESET}"
  echo -e "  ${DIM}──────────────────────────────────────${RESET}"
  echo ""
}

print_status() {
  # ── CA ──
  echo -e "  ${BOLD}CA${RESET}"
  if [[ -f "$CA_DIR/ca.crt" && -f "$CA_DIR/ca.key" ]]; then
    local ca_expiry
    ca_expiry=$(openssl x509 -in "$CA_DIR/ca.crt" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
    echo -e "    ${GREEN}Expires${RESET}  $ca_expiry"

    # Trust status (delegates to trust-ca.sh for platform detection)
    local trust_output
    trust_output=$("$SCRIPTS_DIR/trust-ca.sh" --check 2>&1 || true)
    if echo "$trust_output" | grep -q "NOT TRUSTED"; then
      echo -e "    ${YELLOW}Not trusted${RESET}  in system trust store ${DIM}(option 4 to fix)${RESET}"
    elif echo "$trust_output" | grep -q "TRUSTED"; then
      echo -e "    ${GREEN}Trusted${RESET}  in system trust store"
    fi
  else
    echo -e "    ${RED}Not initialized${RESET}"
  fi
  echo ""

  # ── Certificates ──
  echo -e "  ${BOLD}Certificates${RESET}"
  local count=0
  if [[ -d "$SERVERS_DIR" ]]; then
    for crt in "$SERVERS_DIR"/*/server.crt; do
      [[ -f "$crt" ]] || continue
      local name
      name=$(basename "$(dirname "$crt")")
      local expiry
      expiry=$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
      local domains
      domains=$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null \
        | grep -oE 'DNS:[^ ,]+' | sed 's/DNS://g' | tr '\n' ' ')
      echo -e "    ${CYAN}$name${RESET}  $domains ${DIM}expires $expiry${RESET}"
      count=$((count + 1))
    done
  fi
  if [[ $count -eq 0 ]]; then
    echo -e "    ${DIM}No server certs issued yet${RESET}"
  fi
  echo ""

  # ── Remotes ──
  echo -e "  ${BOLD}Remotes${RESET}"
  local rcount=0
  if [[ -d "$REMOTES_DIR" ]]; then
    for rconf in "$REMOTES_DIR"/*/remote.conf; do
      [[ -f "$rconf" ]] || continue
      local rname rhost
      rname=$(basename "$(dirname "$rconf")")
      rhost=$(grep '^HOST=' "$rconf" | cut -d= -f2-)
      local rsync_info=""
      local rsync_conf
      rsync_conf="$(dirname "$rconf")/last-sync.conf"
      if [[ -f "$rsync_conf" ]]; then
        local rsync_time
        rsync_time=$(grep '^SYNC_TIME=' "$rsync_conf" | cut -d= -f2-)
        local rsync_servers
        rsync_servers=$(grep '^SYNC_SERVERS=' "$rsync_conf" | cut -d= -f2-)
        local scount
        # shellcheck disable=SC2086
        scount=$(echo $rsync_servers | wc -w | tr -d ' ')
        rsync_info="${DIM}synced $rsync_time ($scount server(s))${RESET}"
      else
        rsync_info="${DIM}never synced${RESET}"
      fi
      echo -e "    ${YELLOW}↗ $rname${RESET}  $rhost  $rsync_info"
      rcount=$((rcount + 1))
    done
  fi
  if [[ $rcount -eq 0 ]]; then
    echo -e "    ${DIM}No remotes registered${RESET}"
  fi
  echo ""
}

prompt_choice() {
  local choice
  echo -e "  ${BOLD}What do you want to do?${RESET}" >&2
  echo "" >&2
  echo -e "  ${BOLD}1${RESET}  Initialize the CA ${DIM}(first time)${RESET}" >&2
  echo -e "  ${BOLD}2${RESET}  Certificates ${DIM}(issue, renew, rotate)${RESET}" >&2
  echo -e "  ${BOLD}3${RESET}  Verify a server cert" >&2
  echo -e "  ${BOLD}4${RESET}  Trust / Untrust CA in system trust store" >&2
  echo -e "  ${BOLD}5${RESET}  Remote sync ${DIM}(push certs to SSH targets)${RESET}" >&2
  echo -e "  ${BOLD}6${RESET}  ${RED}Nuke${RESET} ${DIM}(delete certs and keys)${RESET}" >&2
  echo -e "  ${BOLD}q${RESET}  Quit" >&2
  echo "" >&2
  read -rp "  > " choice
  echo "$choice"
}

pick_server() {
  local label="$1"
  local servers=()
  for cnf in "$SERVERS_DIR"/*/san_server.cnf; do
    [[ -f "$cnf" ]] || continue
    servers+=("$(basename "$(dirname "$cnf")")")
  done

  if [[ ${#servers[@]} -eq 0 ]]; then
    echo "" >&2
    echo -e "  ${RED}No existing servers found.${RESET}" >&2
    echo -e "  Issue a cert first (option ${BOLD}2${RESET} → ${BOLD}1${RESET})." >&2
    return 1
  fi

  echo "" >&2
  echo -e "  ${BOLD}$label${RESET}" >&2
  echo "" >&2
  for i in "${!servers[@]}"; do
    echo -e "  ${BOLD}$((i + 1))${RESET}  ${servers[$i]}" >&2
  done
  echo "" >&2
  read -rp "  > " idx

  if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#servers[@]} )); then
    echo -e "  ${RED}Invalid selection.${RESET}" >&2
    return 1
  fi

  echo "${servers[$((idx - 1))]}"
}

prompt_domains() {
  local server="$1"
  echo "" >&2
  echo -e "  ${BOLD}Domains${RESET} ${DIM}(space-separated, e.g. oatmilk.work \"*.oatmilk.work\")${RESET}" >&2

  # Show existing domains as hint if available
  local cnf="$SERVERS_DIR/$server/san_server.cnf"
  if [[ -f "$cnf" ]]; then
    local existing
    existing=$(grep -E '^DNS\.' "$cnf" | sed 's/^[^=]*=\s*//' | tr '\n' ' ')
    if [[ -n "$existing" ]]; then
      echo -e "  ${DIM}Current: $existing${RESET}" >&2
      echo -e "  ${DIM}Press Enter to keep current domains${RESET}" >&2
    fi
  fi

  echo "" >&2
  read -rp "  > " input

  # If empty and existing domains available, reuse them
  if [[ -z "$input" && -f "$cnf" ]]; then
    local domains=()
    while IFS= read -r line; do
      if [[ "$line" =~ ^DNS\.[0-9]+[[:space:]]*=[[:space:]]*(.*) ]]; then
        domains+=("${BASH_REMATCH[1]}")
      fi
    done < "$cnf"
    echo "${domains[*]}"
  else
    echo "$input"
  fi
}

# Global vars set by prompt_options / read_existing_options
OPT_FOREVER=""
OPT_OU=""
OPT_EMAIL=""

prompt_options() {
  OPT_FOREVER=""
  OPT_OU=""
  OPT_EMAIL=""

  echo "" >&2
  echo -e "  ${BOLD}Expiry${RESET}" >&2
  echo -e "  ${BOLD}1${RESET}  1 year ${DIM}(default)${RESET}" >&2
  echo -e "  ${BOLD}2${RESET}  Forever" >&2
  echo "" >&2
  read -rp "  > " expiry_choice
  if [[ "$expiry_choice" == "2" ]]; then OPT_FOREVER="yes"; fi

  echo "" >&2
  echo -e "  ${BOLD}OU${RESET} ${DIM}(default: Backoffice)${RESET}" >&2
  read -rp "  > " ou_input
  if [[ -n "$ou_input" ]]; then OPT_OU="$ou_input"; fi

  echo "" >&2
  echo -e "  ${BOLD}Email${RESET} ${DIM}(default: team@backoffice.oatmilk.work)${RESET}" >&2
  read -rp "  > " email_input
  if [[ -n "$email_input" ]]; then OPT_EMAIL="$email_input"; fi
}

# Read OU/email/forever from an existing server's config and cert
read_existing_options() {
  local server="$1"
  OPT_FOREVER=""
  OPT_OU=""
  OPT_EMAIL=""

  local cnf="$SERVERS_DIR/$server/san_server.cnf"
  if [[ -f "$cnf" ]]; then
    OPT_OU=$(grep -E '^\s*OU\s*=' "$cnf" | head -1 | sed 's/^[^=]*=\s*//')
    OPT_EMAIL=$(grep -E '^\s*emailAddress\s*=' "$cnf" | head -1 | sed 's/^[^=]*=\s*//')
  fi

  local crt="$SERVERS_DIR/$server/server.crt"
  if [[ -f "$crt" ]]; then
    local not_after
    not_after=$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
    if [[ -n "$not_after" ]]; then
      local end_year
      end_year=$(date -j -f "%b %d %T %Y %Z" "$not_after" "+%Y" 2>/dev/null || echo "")
      local current_year
      current_year=$(date "+%Y")
      if [[ -n "$end_year" ]] && (( end_year - current_year > 10 )); then
        OPT_FOREVER="yes"
      fi
    fi
  fi
}

# Build args array from OPT_ globals
build_opt_args() {
  local -n _arr=$1
  if [[ -n "$OPT_FOREVER" ]]; then _arr+=(--forever); fi
  if [[ -n "$OPT_OU" ]]; then _arr+=(--ou "$OPT_OU"); fi
  if [[ -n "$OPT_EMAIL" ]]; then _arr+=(--email "$OPT_EMAIL"); fi
}

wait_for_key() {
  echo ""
  read -rp "  Press Enter to continue..." _
}

# ── Actions ──────────────────────────────────────────────────────────

do_issue() {
  echo ""
  echo -e "  ${BOLD}Server name${RESET} ${DIM}(e.g. traefik, gitea, nextcloud)${RESET}"
  echo ""
  read -rp "  > " server_name

  if [[ -z "$server_name" ]]; then
    echo -e "  ${RED}Server name cannot be empty.${RESET}"
    wait_for_key
    return
  fi

  local domain_input
  domain_input=$(prompt_domains "$server_name")
  if [[ -z "$domain_input" ]]; then
    echo -e "  ${RED}At least one domain is required.${RESET}"
    wait_for_key
    return
  fi

  prompt_options

  local cmd_args=()
  build_opt_args cmd_args
  cmd_args+=("$server_name")

  echo ""
  # shellcheck disable=SC2086
  echo -e "  ${DIM}Running: issue-cert.sh ${cmd_args[*]} $domain_input${RESET}"
  echo ""

  # shellcheck disable=SC2086
  run_script issue-cert.sh "${cmd_args[@]}" $domain_input || true

  wait_for_key
}

do_renew() {
  local server
  server=$(pick_server "Which server to renew?") || { wait_for_key; return; }

  local domain_input
  domain_input=$(prompt_domains "$server")
  if [[ -z "$domain_input" ]]; then
    echo -e "  ${RED}At least one domain is required.${RESET}"
    wait_for_key
    return
  fi

  # Preserve existing settings (OU, email, forever) from the current cert
  read_existing_options "$server"

  local cmd_args=(--renew)
  build_opt_args cmd_args
  cmd_args+=("$server")

  echo ""
  # shellcheck disable=SC2086
  echo -e "  ${DIM}Running: issue-cert.sh ${cmd_args[*]} $domain_input${RESET}"
  echo ""

  # shellcheck disable=SC2086
  run_script issue-cert.sh "${cmd_args[@]}" $domain_input || true

  wait_for_key
}

do_reissue() {
  local server
  server=$(pick_server "Which server to re-issue?") || { wait_for_key; return; }

  local domain_input
  domain_input=$(prompt_domains "$server")
  if [[ -z "$domain_input" ]]; then
    echo -e "  ${RED}At least one domain is required.${RESET}"
    wait_for_key
    return
  fi

  prompt_options

  local cmd_args=()
  build_opt_args cmd_args
  cmd_args+=("$server")

  echo ""
  # shellcheck disable=SC2086
  echo -e "  ${DIM}Running: issue-cert.sh ${cmd_args[*]} $domain_input${RESET}"
  echo ""

  # shellcheck disable=SC2086
  run_script issue-cert.sh "${cmd_args[@]}" $domain_input || true

  wait_for_key
}

do_init_ca() {
  if [[ -f "$CA_DIR/ca.key" ]]; then
    echo ""
    echo -e "  ${YELLOW}CA already exists.${RESET}"
    echo -e "  Use option ${BOLD}2${RESET} → ${BOLD}4${RESET} (Rotate) to regenerate. Or ${BOLD}q${RESET} to go back."
    wait_for_key
    return
  fi

  echo ""
  run_script init-ca.sh || true

  wait_for_key
}

do_rotate() {
  echo ""
  echo -e "  ${BOLD}Server keys${RESET}" >&2
  echo -e "  ${BOLD}1${RESET}  Keep existing server keys ${DIM}(CA compromised, server keys are fine)${RESET}" >&2
  echo -e "  ${BOLD}2${RESET}  Regenerate everything ${DIM}(fresh start)${RESET}" >&2
  echo "" >&2
  read -rp "  > " key_choice

  if [[ "$key_choice" == "1" ]]; then
    run_script rotate-ca.sh --renew || true
  else
    run_script rotate-ca.sh || true
  fi

  wait_for_key
}

do_verify() {
  local server
  server=$(pick_server "Which server to verify?") || { wait_for_key; return; }

  local crt="$SERVERS_DIR/$server/server.crt"
  if [[ ! -f "$crt" ]]; then
    echo -e "  ${RED}No cert found for $server.${RESET}"
    echo -e "  Issue a cert first (option ${BOLD}2${RESET} → ${BOLD}1${RESET})."
    wait_for_key
    return
  fi

  echo ""
  echo -e "  ${BOLD}Chain verification:${RESET}"
  if openssl verify -CAfile "$CA_DIR/ca.crt" "$crt" 2>&1; then
    echo -e "  ${GREEN}Valid${RESET}"
  else
    echo -e "  ${RED}Invalid — cert may have been signed by a different CA.${RESET}"
    echo -e "  Re-issue it (option ${BOLD}2${RESET} → ${BOLD}3${RESET}) or rotate everything (option ${BOLD}2${RESET} → ${BOLD}4${RESET})."
  fi

  echo ""
  echo -e "  ${BOLD}Certificate details:${RESET}"
  echo ""
  openssl x509 -in "$crt" -noout \
    -subject -issuer -dates -serial -ext subjectAltName

  wait_for_key
}

do_nuke() {
  echo ""
  echo -e "  ${RED}${BOLD}Nuke${RESET} ${DIM}— delete certs and keys${RESET}" >&2
  echo "" >&2
  echo -e "  ${BOLD}1${RESET}  Nuke all server certs ${DIM}(keep CA)${RESET}" >&2
  echo -e "  ${BOLD}2${RESET}  Nuke everything ${DIM}(CA + all servers)${RESET}" >&2
  echo -e "  ${BOLD}q${RESET}  Cancel" >&2
  echo "" >&2
  read -rp "  > " nuke_choice

  case "$nuke_choice" in
    1)
      # Count servers
      local count=0
      for d in "$SERVERS_DIR"/*/san_server.cnf; do
        if [[ -f "$d" ]]; then count=$((count + 1)); fi
      done
      if [[ $count -eq 0 ]]; then
        echo -e "  ${DIM}No server certs to delete.${RESET}"
        wait_for_key
        return
      fi
      echo ""
      echo -e "  ${RED}This will delete $count server(s) — keys, certs, and configs.${RESET}"
      echo ""
      for cnf in "$SERVERS_DIR"/*/san_server.cnf; do
        if [[ -f "$cnf" ]]; then
          local sname
          sname=$(basename "$(dirname "$cnf")")
          local sdomains
          sdomains=$(grep -E '^DNS\.' "$cnf" | sed 's/^[^=]*=\s*//' | tr '\n' ' ')
          echo -e "  ${DIM}$sname${RESET}  $sdomains"
        fi
      done
      echo ""
      read -rp "  Type 'nuke' to confirm: " confirm
      if [[ "$confirm" == "nuke" ]]; then
        for d in "$SERVERS_DIR"/*/; do
          if [[ -d "$d" ]]; then
            rm -rf "$d"
          fi
        done
        echo -e "  ${GREEN}All server certs, keys, and configs deleted.${RESET}"
        echo -e "  ${DIM}Issue new certs with option ${BOLD}2${RESET} → ${BOLD}1${RESET}${DIM}.${RESET}"
      else
        echo -e "  ${DIM}Cancelled.${RESET}"
      fi
      ;;
    2)
      echo ""
      echo -e "  ${RED}This will delete EVERYTHING — CA + all server certs, keys, and configs.${RESET}"
      # Show CA details
      if [[ -f "$CA_DIR/ca.crt" ]]; then
        echo ""
        local ca_cn
        ca_cn=$(openssl x509 -in "$CA_DIR/ca.crt" -noout -subject 2>/dev/null \
          | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p')
        local ca_exp
        ca_exp=$(openssl x509 -in "$CA_DIR/ca.crt" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
        echo -e "  ${DIM}CA${RESET}  $ca_cn  ${DIM}expires $ca_exp${RESET}"
      fi
      # List servers if any exist
      local has_servers=false
      for cnf in "$SERVERS_DIR"/*/san_server.cnf; do
        if [[ -f "$cnf" ]]; then
          if [[ "$has_servers" == "false" ]]; then
            echo ""
            has_servers=true
          fi
          local sname
          sname=$(basename "$(dirname "$cnf")")
          local sdomains
          sdomains=$(grep -E '^DNS\.' "$cnf" | sed 's/^[^=]*=\s*//' | tr '\n' ' ')
          echo -e "  ${DIM}$sname${RESET}  $sdomains"
        fi
      done
      echo ""
      read -rp "  Type 'nuke' to confirm: " confirm
      if [[ "$confirm" == "nuke" ]]; then
        # Untrust CA from system trust store before deleting the cert file
        if [[ -f "$CA_DIR/ca.crt" ]]; then
          run_script trust-ca.sh --untrust || true
        fi
        rm -f "$CA_DIR/ca.key" "$CA_DIR/ca.crt" "$CA_DIR/ca.srl" "$CA_DIR/san_ca.cnf"
        for d in "$SERVERS_DIR"/*/; do
          if [[ -d "$d" ]]; then
            rm -rf "$d"
          fi
        done
        echo -e "  ${GREEN}Everything nuked.${RESET}"
        echo -e "  ${DIM}Start fresh with option ${BOLD}1${RESET}${DIM}.${RESET}"
      else
        echo -e "  ${DIM}Cancelled.${RESET}"
      fi
      ;;
    *)
      echo -e "  ${DIM}Cancelled.${RESET}"
      ;;
  esac

  wait_for_key
}

do_trust() {
  echo ""
  echo -e "  ${BOLD}Trust / Untrust CA${RESET}" >&2
  echo "" >&2
  echo -e "  ${BOLD}1${RESET}  Trust CA ${DIM}(add to system trust store — requires sudo)${RESET}" >&2
  echo -e "  ${BOLD}2${RESET}  Untrust CA ${DIM}(remove from system trust store — requires sudo)${RESET}" >&2
  echo -e "  ${BOLD}3${RESET}  Check trust status" >&2
  echo -e "  ${BOLD}q${RESET}  Back" >&2
  echo "" >&2
  read -rp "  > " trust_choice

  case "$trust_choice" in
    1) run_script trust-ca.sh --trust || true ;;
    2) run_script trust-ca.sh --untrust || true ;;
    3) run_script trust-ca.sh --check || true ;;
    *) echo -e "  ${DIM}Back.${RESET}" ;;
  esac

  wait_for_key
}

pick_remote() {
  local label="$1"
  local remotes=()
  for rconf in "$REMOTES_DIR"/*/remote.conf; do
    [[ -f "$rconf" ]] || continue
    remotes+=("$(basename "$(dirname "$rconf")")")
  done

  if [[ ${#remotes[@]} -eq 0 ]]; then
    echo "" >&2
    echo -e "  ${RED}No remotes registered.${RESET}" >&2
    echo -e "  Add one first (option ${BOLD}5${RESET} → ${BOLD}1${RESET})." >&2
    return 1
  fi

  echo "" >&2
  echo -e "  ${BOLD}$label${RESET}" >&2
  echo "" >&2
  for i in "${!remotes[@]}"; do
    local rhost
    rhost=$(grep '^HOST=' "$REMOTES_DIR/${remotes[$i]}/remote.conf" | cut -d= -f2-)
    echo -e "  ${BOLD}$((i + 1))${RESET}  ${remotes[$i]}  ${DIM}($rhost)${RESET}" >&2
  done
  echo "" >&2
  read -rp "  > " idx

  if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#remotes[@]} )); then
    echo -e "  ${RED}Invalid selection.${RESET}" >&2
    return 1
  fi

  echo "${remotes[$((idx - 1))]}"
}

do_remote_add() {
  echo ""
  echo -e "  ${BOLD}Remote name${RESET} ${DIM}(e.g. prod-web, staging)${RESET}"
  echo ""
  read -rp "  > " rname

  if [[ -z "$rname" ]]; then
    echo -e "  ${RED}Remote name cannot be empty.${RESET}"
    return
  fi

  echo ""
  echo -e "  ${BOLD}Host${RESET} ${DIM}(e.g. root@192.168.1.10)${RESET}"
  echo ""
  read -rp "  > " rhost

  if [[ -z "$rhost" ]]; then
    echo -e "  ${RED}Host cannot be empty.${RESET}"
    return
  fi

  echo ""
  echo -e "  ${BOLD}SSH port${RESET} ${DIM}(default: 22)${RESET}"
  echo ""
  read -rp "  > " rport
  rport="${rport:-22}"

  echo ""
  echo -e "  ${BOLD}SSH key path${RESET} ${DIM}(optional, press Enter to skip)${RESET}"
  echo ""
  read -rp "  > " rkey

  local cmd_args=("$rname" --host "$rhost" --port "$rport")
  if [[ -n "$rkey" ]]; then
    cmd_args+=(--key "$rkey")
  fi

  echo ""
  run_script remote-sync.sh --add "${cmd_args[@]}" || true
}

do_remote_remove() {
  local rname
  rname=$(pick_remote "Which remote to remove?") || return

  echo ""
  run_script remote-sync.sh --remove "$rname" || true
}

is_remote_synced() {
  local name="$1"
  local sync_conf="$REMOTES_DIR/$name/last-sync.conf"
  [[ -f "$sync_conf" ]] || return 1

  local SYNC_TIME="" SYNC_SERVERS="" SYNC_HASH=""
  # shellcheck disable=SC1090
  source "$sync_conf"
  [[ -n "$SYNC_HASH" ]] || return 1

  # Recompute current hash and compare
  [[ -f "$CA_DIR/ca.crt" ]] || return 1
  local servers=()
  for crt in "$SERVERS_DIR"/*/server.crt; do
    [[ -f "$crt" ]] || continue
    servers+=("$(basename "$(dirname "$crt")")")
  done
  local current_hash
  current_hash=$( {
    cat "$CA_DIR/ca.crt"
    for sname in $(printf '%s\n' "${servers[@]}" | sort); do
      cat "$SERVERS_DIR/$sname/server.crt" "$SERVERS_DIR/$sname/server.key"
    done
  } | shasum -a 256 | cut -d' ' -f1 )

  [[ "$SYNC_HASH" == "$current_hash" ]]
}

# Interactive multi-select picker for sync targets.
# Returns space-separated list of selected remote names on stdout.
# Navigation: j/k or ↑/↓, space to toggle, enter to confirm, q to cancel.
pick_sync_targets() {
  local remotes=() hosts=() synced=()

  for rconf in "$REMOTES_DIR"/*/remote.conf; do
    [[ -f "$rconf" ]] || continue
    remotes+=("$(basename "$(dirname "$rconf")")")
    hosts+=("$(grep '^HOST=' "$rconf" | cut -d= -f2-)")
    if is_remote_synced "${remotes[-1]}"; then
      synced+=("yes")
    else
      synced+=("no")
    fi
  done

  if [[ ${#remotes[@]} -eq 0 ]]; then
    echo -e "  ${RED}No remotes registered.${RESET}" >&2
    echo -e "  Add one first (option ${BOLD}5${RESET} → ${BOLD}1${RESET})." >&2
    return 1
  fi

  local any_stale=false
  for flag in "${synced[@]}"; do
    if [[ "$flag" == "no" ]]; then any_stale=true; break; fi
  done

  if ! $any_stale; then
    echo -e "  ${GREEN}All remotes are up to date.${RESET}" >&2
    return 1
  fi

  local n=${#remotes[@]}
  local total=$((n + 1))   # index 0 = "All remotes"
  local sel=()
  local cur=0

  for ((i=0; i<total; i++)); do sel+=(0); done

  # Pre-select all stale remotes and "All"
  sel[0]=1
  for ((i=0; i<n; i++)); do
    if [[ "${synced[$i]}" == "no" ]]; then sel[$((i+1))]=1; fi
  done

  tput civis >&2 2>/dev/null   # hide cursor

  echo "" >&2
  echo -e "  ${BOLD}Select remotes to sync${RESET}" >&2

  _draw_sync_picker() {
    for ((i=0; i<total; i++)); do
      local arrow="  "
      [[ $i -eq $cur ]] && arrow="→ "

      local box="[ ]"
      [[ ${sel[$i]} -eq 1 ]] && box="[x]"

      if [[ $i -eq 0 ]]; then
        printf "  %s %s All remotes\033[K\n" "$arrow" "$box" >&2
      else
        local idx=$((i - 1))
        if [[ "${synced[$idx]}" == "yes" ]]; then
          printf "  %s \033[2m%s %s  %s (synced)\033[0m\033[K\n" "$arrow" "$box" "${remotes[$idx]}" "${hosts[$idx]}" >&2
        else
          printf "  %s \033[1m%s\033[0m %s  \033[2m%s\033[0m\033[K\n" "$arrow" "$box" "${remotes[$idx]}" "${hosts[$idx]}" >&2
        fi
      fi
    done
    echo -e "\033[K" >&2
    echo -e "  ${DIM}↑↓/jk navigate  space toggle  enter sync  q back${RESET}\033[K" >&2
  }

  _draw_sync_picker
  local redraw_up=$((total + 2))

  while true; do
    local key
    IFS= read -rsn1 key

    if [[ "$key" == $'\x1b' ]]; then
      local seq
      IFS= read -rsn2 seq
      case "$seq" in
        '[A') key='k' ;;
        '[B') key='j' ;;
      esac
    fi

    case "$key" in
      k)
        (( cur > 0 )) && cur=$((cur - 1))
        ;;
      j)
        (( cur < total - 1 )) && cur=$((cur + 1))
        ;;
      ' ')
        if [[ $cur -eq 0 ]]; then
          # Toggle "All remotes"
          if [[ ${sel[0]} -eq 0 ]]; then
            sel[0]=1
            for ((i=0; i<n; i++)); do
              [[ "${synced[$i]}" == "no" ]] && sel[$((i+1))]=1
            done
          else
            for ((i=0; i<total; i++)); do sel[$i]=0; done
          fi
        else
          local idx=$((cur - 1))
          if [[ "${synced[$idx]}" == "no" ]]; then
            sel[$cur]=$(( 1 - sel[$cur] ))
            # Auto-update "All" checkbox
            local all_on=true
            for ((i=0; i<n; i++)); do
              if [[ "${synced[$i]}" == "no" && ${sel[$((i+1))]} -eq 0 ]]; then
                all_on=false; break
              fi
            done
            if $all_on; then sel[0]=1; else sel[0]=0; fi
          fi
        fi
        ;;
      ''|$'\n')
        break
        ;;
      q|Q)
        tput cnorm >&2 2>/dev/null
        echo "" >&2
        return 1
        ;;
    esac

    printf "\033[%dA" "$redraw_up" >&2
    _draw_sync_picker
  done

  tput cnorm >&2 2>/dev/null

  local result=()
  for ((i=0; i<n; i++)); do
    [[ ${sel[$((i+1))]} -eq 1 ]] && result+=("${remotes[$i]}")
  done

  if [[ ${#result[@]} -eq 0 ]]; then
    echo "" >&2
    return 1
  fi

  echo "${result[*]}"
}

do_remote_sync() {
  local selected
  selected=$(pick_sync_targets) || { wait_for_key; return; }

  echo ""
  for rname in $selected; do
    run_script remote-sync.sh --sync "$rname" || true
  done
}

do_remote() {
  echo ""
  echo -e "  ${BOLD}Remote Sync${RESET}" >&2
  echo "" >&2

  # Auto-show detailed status for all remotes
  run_script remote-sync.sh --list || true

  echo "" >&2
  echo -e "  ${BOLD}1${RESET}  Add a remote" >&2
  echo -e "  ${BOLD}2${RESET}  Remove a remote" >&2
  echo -e "  ${BOLD}3${RESET}  Sync" >&2
  echo -e "  ${BOLD}q${RESET}  Back" >&2
  echo "" >&2
  read -rp "  > " remote_choice

  case "$remote_choice" in
    1) do_remote_add ;;
    2) do_remote_remove ;;
    3) do_remote_sync ;;
    *) echo -e "  ${DIM}Back.${RESET}" ;;
  esac

  wait_for_key
}

do_certs() {
  echo ""
  echo -e "  ${BOLD}Certificates${RESET}" >&2
  echo "" >&2
  echo -e "  ${BOLD}1${RESET}  Issue a new server cert" >&2
  echo -e "  ${BOLD}2${RESET}  Renew a server cert ${DIM}(keep existing server.key)${RESET}" >&2
  echo -e "  ${BOLD}3${RESET}  Re-issue a server cert ${DIM}(new server.key + cert)${RESET}" >&2
  echo -e "  ${BOLD}4${RESET}  Rotate CA + all server certs" >&2
  echo -e "  ${BOLD}q${RESET}  Back" >&2
  echo "" >&2
  read -rp "  > " cert_choice

  case "$cert_choice" in
    1) do_issue ;;
    2) do_renew ;;
    3) do_reissue ;;
    4) do_rotate ;;
    *) echo -e "  ${DIM}Back.${RESET}" ;;
  esac
}

# ── Main loop ────────────────────────────────────────────────────────

while true; do
  print_header
  print_status
  choice=$(prompt_choice)

  case "$choice" in
    1) do_init_ca ;;
    2) do_certs ;;
    3) do_verify ;;
    4) do_trust ;;
    5) do_remote ;;
    6) do_nuke ;;
    q|Q) echo ""; exit 0 ;;
    *) echo -e "  ${RED}Invalid choice.${RESET}"; sleep 1 ;;
  esac
done

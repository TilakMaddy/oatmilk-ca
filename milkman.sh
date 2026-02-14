#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$BASE_DIR/scripts"
CA_DIR="$BASE_DIR/oatca"
SERVERS_DIR="$BASE_DIR/servers"

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
      echo -e "  ${BOLD}1${RESET}  Initialize the CA        (if CA doesn't exist)"
      echo -e "  ${BOLD}5${RESET}  Rotate CA + all certs    (if CA exists and you want to regenerate)"
      ;;
    issue-cert.sh)
      if [[ ! -f "$CA_DIR/ca.crt" || ! -f "$CA_DIR/ca.key" ]]; then
        echo -e "  ${BOLD}1${RESET}  Initialize the CA first, then try again"
      else
        echo -e "  ${BOLD}2${RESET}  Issue a new server cert  (fresh key + cert)"
        echo -e "  ${BOLD}3${RESET}  Renew a server cert      (keep existing key)"
      fi
      ;;
    rotate-ca.sh)
      echo -e "  ${BOLD}1${RESET}  Initialize the CA        (if starting fresh)"
      echo -e "  ${BOLD}5${RESET}  Rotate again             (if it was interrupted)"
      ;;
    trust-ca.sh)
      echo -e "  ${BOLD}8${RESET}  Trust / Untrust CA       (try again)"
      echo -e "  ${BOLD}1${RESET}  Initialize the CA        (if CA doesn't exist)"
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
  # CA status
  if [[ -f "$CA_DIR/ca.crt" && -f "$CA_DIR/ca.key" ]]; then
    local ca_expiry
    ca_expiry=$(openssl x509 -in "$CA_DIR/ca.crt" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
    echo -e "  ${GREEN}CA${RESET}  $ca_expiry"

    # Trust status (delegates to trust-ca.sh for platform detection)
    local trust_output
    trust_output=$("$SCRIPTS_DIR/trust-ca.sh" --check 2>&1 || true)
    if echo "$trust_output" | grep -q "NOT TRUSTED"; then
      echo -e "  ${YELLOW}Not trusted${RESET}  in system trust store ${DIM}(option 8 to fix)${RESET}"
    elif echo "$trust_output" | grep -q "TRUSTED"; then
      echo -e "  ${GREEN}Trusted${RESET}  in system trust store"
    fi
  else
    echo -e "  ${RED}CA${RESET}  not initialized"
  fi

  # Server certs
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
      echo -e "  ${CYAN}$name${RESET}  $domains ${DIM}expires $expiry${RESET}"
      count=$((count + 1))
    done
  fi
  if [[ $count -eq 0 ]]; then
    echo -e "  ${DIM}No server certs issued yet${RESET}"
  fi
  echo ""
}

prompt_choice() {
  local choice
  echo -e "  ${BOLD}What do you want to do?${RESET}" >&2
  echo "" >&2
  echo -e "  ${BOLD}1${RESET}  Initialize the CA ${DIM}(first time)${RESET}" >&2
  echo -e "  ${BOLD}2${RESET}  Issue a new server cert" >&2
  echo -e "  ${BOLD}3${RESET}  Renew a server cert ${DIM}(keep existing server.key)${RESET}" >&2
  echo -e "  ${BOLD}4${RESET}  Re-issue a server cert ${DIM}(new server.key + cert)${RESET}" >&2
  echo -e "  ${BOLD}5${RESET}  Rotate CA + all server certs" >&2
  echo -e "  ${BOLD}6${RESET}  Verify a server cert" >&2
  echo -e "  ${BOLD}7${RESET}  ${RED}Nuke${RESET} ${DIM}(delete certs and keys)${RESET}" >&2
  echo -e "  ${BOLD}8${RESET}  Trust / Untrust CA in system trust store" >&2
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
    echo -e "  Issue a cert first (option ${BOLD}2${RESET})." >&2
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
    echo -e "  Use option ${BOLD}5${RESET} (Rotate) to regenerate. Or ${BOLD}q${RESET} to go back."
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
    echo -e "  Issue a cert first (option ${BOLD}2${RESET})."
    wait_for_key
    return
  fi

  echo ""
  echo -e "  ${BOLD}Chain verification:${RESET}"
  if openssl verify -CAfile "$CA_DIR/ca.crt" "$crt" 2>&1; then
    echo -e "  ${GREEN}Valid${RESET}"
  else
    echo -e "  ${RED}Invalid — cert may have been signed by a different CA.${RESET}"
    echo -e "  Re-issue it (option ${BOLD}4${RESET}) or rotate everything (option ${BOLD}5${RESET})."
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
        echo -e "  ${DIM}Issue new certs with option ${BOLD}2${RESET}${DIM}.${RESET}"
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

# ── Main loop ────────────────────────────────────────────────────────

while true; do
  print_header
  print_status
  choice=$(prompt_choice)

  case "$choice" in
    1) do_init_ca ;;
    2) do_issue ;;
    3) do_renew ;;
    4) do_reissue ;;
    5) do_rotate ;;
    6) do_verify ;;
    7) do_nuke ;;
    8) do_trust ;;
    q|Q) echo ""; exit 0 ;;
    *) echo -e "  ${RED}Invalid choice.${RESET}"; sleep 1 ;;
  esac
done

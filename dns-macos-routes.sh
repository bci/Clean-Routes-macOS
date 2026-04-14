#!/usr/bin/env zsh
# dns-macos-routes.sh — manage macOS conditional DNS profiles
# Reads/writes /etc/resolver/<domain> files and optionally manages
# the associated static routes via networksetup.
# Usage: ./dns-macos-routes.sh [OPTIONS]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ── globals ───────────────────────────────────────────────────────────────────
DRY_RUN=0
VERBOSE=0
ASSUME_YES=0

ACTION=""
PROFILE_NAMES=()
ROUTES_FILE="${ROUTES_JSON_DEFAULT}"
WITH_ROUTES=0
LOCAL_ROUTER_OVERRIDE=""
NETWORK_SERVICE_OVERRIDE=""
BACKUP_PATH=""
RESTORE_PATH=""
DIFF_NAMES=()
SAVE_NAME=""
SAVE_DOMAIN=""
DELETE_NAME=""
RENAME_OLD=""
RENAME_NEW=""

usage() {
  cat << 'USAGE'
Usage: dns-macos-routes.sh [OPTIONS]

Manage macOS conditional DNS profiles backed by routes.json.
Writes /etc/resolver/<domain> files; optionally manages associated static routes.

Actions:
  --list                    Print all profiles from the JSON file
  --show                    Print current /etc/resolver/ files and their content
  --apply <name> [name2…]   Write /etc/resolver/<domain> for each profile (root)
  --remove <name> [name2…]  Delete /etc/resolver/<domain> for each profile (root)
  --remove-all              Remove ALL files under /etc/resolver/ (root)
  --diff <name> [name2…]    Compare JSON profile(s) vs live /etc/resolver/ + routes
  --save <name>             Create/update a JSON profile from a live /etc/resolver/ file
                            (use --domain <domain> to specify which file to read)
  --delete <name>           Remove a profile from the JSON file (no /etc/resolver/ change)
  --rename <old> <new>      Rename a profile in the JSON file
  --backup [<file>]         Snapshot current /etc/resolver/ to a JSON archive
  --restore <file>          Restore /etc/resolver/ files from a JSON archive (root)
  --flush-cache             Flush DNS cache (root)
  --test <name> [name2…]    Run dscacheutil + ping tests for profile(s)

Modifiers:
  --load <path>             JSON routes file (default: ~/.config/macos-routes/routes.json)
  --with-routes             Also apply/remove networks routes via networksetup
  --local-router <IP>       Override local_router for this invocation
  --service <svc>           Override network service for networksetup operations
  --domain <domain>         Domain to read when using --save on a new profile

Flags:
  -n, --dry-run             Print commands; do not execute
  -v, --verbose             Show commands before running
  -y, --yes                 Skip confirmation prompts
  -h, --help                Show this help

Examples:
  dns-macos-routes.sh --list
  dns-macos-routes.sh --show
  sudo dns-macos-routes.sh --apply gardena mde --with-routes
  sudo dns-macos-routes.sh --remove gardena --with-routes
  dns-macos-routes.sh --diff gardena mde
  dns-macos-routes.sh --save gardena --domain ci.gardena.ca.us
  dns-macos-routes.sh --backup
  sudo dns-macos-routes.sh --restore ~/.config/macos-routes/backups/2026-01-01T12-00-00-dns.json
  dns-macos-routes.sh --test gardena mde
USAGE
}

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)        ACTION="list"; shift ;;
    --show)        ACTION="show"; shift ;;
    --apply)
      ACTION="apply"; shift
      while [[ $# -gt 0 && "${1:-}" != -* ]]; do
        PROFILE_NAMES+=("$1"); shift
      done
      [[ ${#PROFILE_NAMES[@]} -eq 0 ]] && { err "--apply requires at least one profile name"; exit 1; }
      ;;
    --remove)
      ACTION="remove"; shift
      while [[ $# -gt 0 && "${1:-}" != -* ]]; do
        PROFILE_NAMES+=("$1"); shift
      done
      [[ ${#PROFILE_NAMES[@]} -eq 0 ]] && { err "--remove requires at least one profile name"; exit 1; }
      ;;
    --remove-all)  ACTION="remove-all"; shift ;;
    --diff)
      ACTION="diff"; shift
      while [[ $# -gt 0 && "${1:-}" != -* ]]; do
        DIFF_NAMES+=("$1"); shift
      done
      [[ ${#DIFF_NAMES[@]} -eq 0 ]] && { err "--diff requires at least one profile name"; exit 1; }
      ;;
    --save)
      ACTION="save"
      SAVE_NAME="${2:?--save requires a profile name}"; shift 2 ;;
    --delete)
      ACTION="delete"
      DELETE_NAME="${2:?--delete requires a profile name}"; shift 2 ;;
    --rename)
      ACTION="rename"
      RENAME_OLD="${2:?--rename requires <old>}"; shift
      RENAME_NEW="${2:?--rename requires <new>}"; shift 2 ;;
    --backup)
      ACTION="backup"
      if [[ "${2:-}" != "" && "${2:-}" != -* ]]; then
        BACKUP_PATH="$2"; shift 2
      else
        shift
      fi ;;
    --restore)
      ACTION="restore"
      RESTORE_PATH="${2:?--restore requires a file}"; shift 2 ;;
    --flush-cache) ACTION="flush-cache"; shift ;;
    --test)
      ACTION="test"; shift
      while [[ $# -gt 0 && "${1:-}" != -* ]]; do
        PROFILE_NAMES+=("$1"); shift
      done
      [[ ${#PROFILE_NAMES[@]} -eq 0 ]] && { err "--test requires at least one profile name"; exit 1; }
      ;;
    --load)        ROUTES_FILE="${2:?--load requires a path}"; shift 2 ;;
    --with-routes) WITH_ROUTES=1; shift ;;
    --local-router) LOCAL_ROUTER_OVERRIDE="${2:?--local-router requires an IP}"; shift 2 ;;
    --service)     NETWORK_SERVICE_OVERRIDE="${2:?--service requires a service name}"; shift 2 ;;
    --domain)      SAVE_DOMAIN="${2:?--domain requires a domain name}"; shift 2 ;;
    -n|--dry-run)  DRY_RUN=1; shift ;;
    -v|--verbose)  VERBOSE=1; shift ;;
    -y|--yes)      ASSUME_YES=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "$ACTION" ]]; then
  err "No action specified."
  usage
  exit 1
fi

# ── helpers ───────────────────────────────────────────────────────────────────

# Return the first active Ethernet or Wi-Fi network service name
_active_service() {
  if [[ -n "$NETWORK_SERVICE_OVERRIDE" ]]; then
    printf '%s' "$NETWORK_SERVICE_OVERRIDE"
    return 0
  fi
  local svc
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    # Prefer Ethernet first, then Wi-Fi
    case "$svc" in
      *Ethernet*|*Thunderbolt*|*USB*|*Wi-Fi*|*AirPort*)
        printf '%s' "$svc"; return 0 ;;
    esac
  done < <(ns_list_services)
  # Fall back to first available
  ns_list_services | head -1
}

# Read a profile from the JSON file via python3.
# Prints JSON to stdout or exits with code 1 if not found.
_get_profile_json() {
  local name="$1"
  python3 - "$ROUTES_FILE" "$name" << 'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
profiles = data.get("dns", {}).get("profiles", {})
name = sys.argv[2]
if name not in profiles:
    print(f"Profile '{name}' not found in {sys.argv[1]}", file=sys.stderr)
    sys.exit(1)
print(json.dumps(profiles[name]))
PYEOF
}

# Get the global local_router from dns.local_router (empty if not set)
_global_local_router() {
  python3 - "$ROUTES_FILE" << 'PYEOF' 2>/dev/null || true
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
print(data.get("dns", {}).get("local_router", ""))
PYEOF
}

# Resolve local_router for a profile (profile > global > flag override > error)
_resolve_router() {
  local profile_json="$1"
  local router
  # flag override wins if set
  if [[ -n "$LOCAL_ROUTER_OVERRIDE" ]]; then
    printf '%s' "$LOCAL_ROUTER_OVERRIDE"; return 0
  fi
  # profile-level
  router=$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('local_router',''))" "$profile_json" 2>/dev/null || true)
  if [[ -n "$router" ]]; then printf '%s' "$router"; return 0; fi
  # global
  router=$(_global_local_router)
  printf '%s' "$router"
}

# Apply networksetup additional routes for a profile, merging with existing ones
_apply_routes_for_profile() {
  local profile_json="$1"
  local svc="$2"
  local router="$3"

  if [[ -z "$router" ]]; then
    err "  No local_router defined for this profile. Use --local-router or add 'local_router' to the JSON."
    return 1
  fi

  local apply_py
  apply_py=$(mktemp "${TMPDIR:-/tmp}/dns-apply-routes.XXXXXX")

  cat > "$apply_py" << 'PYEOF'
import sys, json, subprocess, ipaddress

profile_json = sys.argv[1]
svc          = sys.argv[2]
router       = sys.argv[3]

profile = json.loads(profile_json)
networks = profile.get("networks", [])
if not networks:
    sys.exit(0)

# Get existing additional routes for this service
existing = []
out = subprocess.run(
    ["networksetup", "-getadditionalroutes", svc],
    capture_output=True, text=True
).stdout
for line in out.splitlines():
    if "aren't any" in line or "There aren" in line:
        continue
    parts = line.split()
    if len(parts) >= 3:
        existing.append((parts[0], parts[1], parts[2]))

# Build new entries from profile networks (CIDR -> dest+mask)
new_entries = []
for cidr in networks:
    net = ipaddress.ip_network(cidr, strict=False)
    new_entries.append((str(net.network_address), str(net.netmask), router))

# Merge: existing entries not in new_entries + new_entries (dedup by dest+mask)
seen = set()
merged = []
for entry in new_entries + existing:
    key = (entry[0], entry[1])
    if key not in seen:
        seen.add(key)
        merged.append(entry)

# Build networksetup args
args = ["networksetup", "-setadditionalroutes", svc]
for dest, mask, gw in merged:
    args += [dest, mask, gw]

print(" ".join(f'"{a}"' if " " in a else a for a in args))
PYEOF

  local cmd
  cmd=$(python3 "$apply_py" "$profile_json" "$svc" "$router")
  rm -f "$apply_py"

  if [[ -n "$cmd" ]]; then
    run_or_echo "$cmd"
  fi
}

# Remove networksetup additional routes that match a profile's networks
_remove_routes_for_profile() {
  local profile_json="$1"
  local svc="$2"

  local remove_py
  remove_py=$(mktemp "${TMPDIR:-/tmp}/dns-remove-routes.XXXXXX")

  cat > "$remove_py" << 'PYEOF'
import sys, json, subprocess, ipaddress

profile_json = sys.argv[1]
svc          = sys.argv[2]

profile = json.loads(profile_json)
networks = profile.get("networks", [])

# Get existing additional routes
existing = []
out = subprocess.run(
    ["networksetup", "-getadditionalroutes", svc],
    capture_output=True, text=True
).stdout
for line in out.splitlines():
    parts = line.split()
    if len(parts) >= 3:
        existing.append((parts[0], parts[1], parts[2]))

if not existing:
    sys.exit(0)

# Normalise profile CIDRs to (network_address, netmask) tuples
to_remove = set()
for cidr in networks:
    net = ipaddress.ip_network(cidr, strict=False)
    to_remove.add((str(net.network_address), str(net.netmask)))

remaining = [(d, m, g) for d, m, g in existing if (d, m) not in to_remove]

if remaining:
    args = ["networksetup", "-setadditionalroutes", svc]
    for dest, mask, gw in remaining:
        args += [dest, mask, gw]
    print(" ".join(f'"{a}"' if " " in a else a for a in args))
else:
    # Pass empty string to clear all routes
    print(f'networksetup -setadditionalroutes "{svc}"')
PYEOF

  local cmd
  cmd=$(python3 "$remove_py" "$profile_json" "$svc")
  rm -f "$remove_py"

  if [[ -n "$cmd" ]]; then
    run_or_echo "$cmd"
  fi
}

# Run dscacheutil + ping tests for a profile
_test_profile() {
  local name="$1"
  local profile_json="$2"

  local test_host ping_host
  test_host=$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('test_host',''))" "$profile_json" 2>/dev/null || true)
  ping_host=$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('ping_host',''))" "$profile_json" 2>/dev/null || true)

  info "  Testing profile: $name"
  if [[ -n "$test_host" ]]; then
    local resolved
    resolved=$(dscacheutil -q host -a name "$test_host" 2>/dev/null | awk '/ip_address/ {print $2}' | tr '\n' ' ' || true)
    if [[ -n "$resolved" ]]; then
      ok "    dscacheutil $test_host → $resolved"
    else
      warn "    dscacheutil $test_host → [FAILED]"
    fi
  else
    info "    (no test_host configured)"
  fi

  if [[ -n "$ping_host" ]]; then
    if ping -c2 -W2 "$ping_host" &>/dev/null; then
      ok "    ping $ping_host → [REACHABLE]"
    else
      warn "    ping $ping_host → [UNREACHABLE]"
    fi
  fi
}

# ── action: list ──────────────────────────────────────────────────────────────
do_list() {
  [[ -f "$ROUTES_FILE" ]] || { err "No routes file: $ROUTES_FILE"; exit 1; }

  python3 - "$ROUTES_FILE" << 'PYEOF'
import sys, json

with open(sys.argv[1]) as f:
    data = json.load(f)

profiles = data.get("dns", {}).get("profiles", {})
if not profiles:
    print("  (no DNS profiles configured)")
    sys.exit(0)

fmt = "  {:<18} {:<28} {:<22} {}"
print(fmt.format("Profile", "Domain", "Nameservers", "Networks"))
print("  " + "-" * 80)

for name, p in profiles.items():
    nss  = p.get("nameservers", [])
    nets = p.get("networks", [])
    domain = p.get("domain", "")
    first_ns  = nss[0]  if nss  else ""
    first_net = nets[0] if nets else ""
    print(fmt.format(name, domain, first_ns, first_net))
    for ns in nss[1:]:
        print(fmt.format("", "", ns, ""))
    for net in nets[1:]:
        print(fmt.format("", "", "", net))
PYEOF
}

# ── action: show ──────────────────────────────────────────────────────────────
do_show() {
  # Build a map of domain → profile name from JSON (if available)
  local domain_map="{}"
  if [[ -f "$ROUTES_FILE" ]]; then
    domain_map=$(python3 - "$ROUTES_FILE" << 'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
profiles = data.get("dns", {}).get("profiles", {})
# domain → profile_name
m = {p.get("domain",""): n for n, p in profiles.items()}
print(json.dumps(m))
PYEOF
    )
  fi

  if [[ ! -d "${RESOLVER_DIR}" ]] || [[ -z "$(ls "${RESOLVER_DIR}/" 2>/dev/null)" ]]; then
    info "No files in ${RESOLVER_DIR}"
    return 0
  fi

  for f in "${RESOLVER_DIR}"/*; do
    local domain
    domain=$(basename "$f")
    local tracked
    tracked=$(python3 -c "import sys,json; m=json.loads(sys.argv[1]); print(m.get(sys.argv[2],''))" "$domain_map" "$domain" 2>/dev/null || true)
    if [[ -n "$tracked" ]]; then
      printf "\n%s  [tracked: %s]\n" "${RESOLVER_DIR}/${domain}" "$tracked"
    else
      printf "\n%s  [UNTRACKED]\n" "${RESOLVER_DIR}/${domain}"
    fi
    sed 's/^/  /' "$f"
  done
  echo
}

# ── action: apply ─────────────────────────────────────────────────────────────
do_apply() {
  require_root
  [[ -f "$ROUTES_FILE" ]] || { err "Routes file not found: $ROUTES_FILE"; exit 1; }

  local svc=""
  if [[ $WITH_ROUTES -eq 1 ]]; then
    svc=$(_active_service)
    [[ -z "$svc" ]] && { err "Could not determine an active network service. Use --service <svc>."; exit 1; }
    [[ $VERBOSE -eq 1 ]] && info "Using network service: $svc"
  fi

  for name in "${PROFILE_NAMES[@]}"; do
    local profile_json domain nameservers
    profile_json=$(_get_profile_json "$name") || exit 1
    domain=$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('domain',''))" "$profile_json")
    [[ -z "$domain" ]] && { err "Profile '$name' has no 'domain' field."; exit 1; }

    nameservers=()
    while IFS= read -r ns; do
      [[ -n "$ns" ]] && nameservers+=("$ns")
    done < <(python3 -c "import sys,json; d=json.loads(sys.argv[1]); [print(n) for n in d.get('nameservers',[])]" "$profile_json")

    [[ ${#nameservers[@]} -eq 0 ]] && { err "Profile '$name' has no nameservers."; exit 1; }

    info "Applying profile '$name' → ${RESOLVER_DIR}/${domain}"
    if [[ $DRY_RUN -eq 1 ]]; then
      printf "[DRY-RUN] write_resolver_file %s %s\n" "$domain" "${nameservers[*]}"
    else
      write_resolver_file "$domain" "${nameservers[@]}"
      ok "  Wrote ${RESOLVER_DIR}/${domain}"
    fi

    if [[ $WITH_ROUTES -eq 1 ]]; then
      local router
      router=$(_resolve_router "$profile_json")
      info "  Applying routes for '$name' via $svc (router: ${router:-MISSING})"
      _apply_routes_for_profile "$profile_json" "$svc" "$router"
    fi
  done

  info "Flushing DNS cache..."
  flush_dns_cache

  ok "Applied ${#PROFILE_NAMES[@]} profile(s)."
}

# ── action: remove ────────────────────────────────────────────────────────────
do_remove() {
  require_root
  [[ -f "$ROUTES_FILE" ]] || { err "Routes file not found: $ROUTES_FILE"; exit 1; }

  local svc=""
  if [[ $WITH_ROUTES -eq 1 ]]; then
    svc=$(_active_service)
    [[ -z "$svc" ]] && { err "Could not determine an active network service. Use --service <svc>."; exit 1; }
    [[ $VERBOSE -eq 1 ]] && info "Using network service: $svc"
  fi

  for name in "${PROFILE_NAMES[@]}"; do
    local profile_json domain
    profile_json=$(_get_profile_json "$name") || exit 1
    domain=$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('domain',''))" "$profile_json")
    [[ -z "$domain" ]] && { err "Profile '$name' has no 'domain' field."; exit 1; }

    local resolver_file="${RESOLVER_DIR}/${domain}"
    if [[ -f "$resolver_file" ]]; then
      info "Removing ${resolver_file}"
      run_or_echo "rm -f \"$resolver_file\""
    else
      warn "  ${resolver_file} already absent — skipping"
    fi

    if [[ $WITH_ROUTES -eq 1 ]]; then
      info "  Removing routes for '$name' via $svc"
      _remove_routes_for_profile "$profile_json" "$svc"
    fi
  done

  info "Flushing DNS cache..."
  flush_dns_cache

  ok "Removed ${#PROFILE_NAMES[@]} profile(s)."
}

# ── action: remove-all ────────────────────────────────────────────────────────
do_remove_all() {
  require_root
  confirm "Delete ALL files under ${RESOLVER_DIR}/? (routes are NOT touched)"

  if [[ $DRY_RUN -eq 1 ]]; then
    info "[DRY-RUN] Would delete all files under ${RESOLVER_DIR}/"
    flush_dns_cache
    return 0
  fi

  if [[ -d "${RESOLVER_DIR}" ]]; then
    find "${RESOLVER_DIR}" -maxdepth 1 -type f | while read -r f; do
      run_or_echo "rm -f \"$f\""
    done
  fi

  info "Flushing DNS cache..."
  flush_dns_cache
  ok "All resolver files removed."
}

# ── action: diff ──────────────────────────────────────────────────────────────
do_diff() {
  [[ -f "$ROUTES_FILE" ]] || { err "Routes file not found: $ROUTES_FILE"; exit 1; }

  for name in "${DIFF_NAMES[@]}"; do
    local profile_json
    profile_json=$(_get_profile_json "$name") || exit 1

    local domain nameservers networks router
    domain=$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('domain',''))" "$profile_json")
    test_host=$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('test_host',''))" "$profile_json" 2>/dev/null || true)
    ping_host=$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get('ping_host',''))" "$profile_json" 2>/dev/null || true)

    printf "\nProfile: %s  (domain: %s)\n" "$name" "$domain"

    # Resolver file check
    local resolver_file="${RESOLVER_DIR}/${domain}"
    printf "\nResolver file (%s):\n" "$resolver_file"
    while IFS= read -r ns; do
      [[ -z "$ns" ]] && continue
      if [[ -f "$resolver_file" ]] && grep -q "nameserver $ns" "$resolver_file" 2>/dev/null; then
        printf "  nameserver %-20s [PRESENT]\n" "$ns"
      else
        printf "  nameserver %-20s [MISSING]\n" "$ns"
      fi
    done < <(python3 -c "import sys,json; d=json.loads(sys.argv[1]); [print(n) for n in d.get('nameservers',[])]" "$profile_json")

    if [[ ! -f "$resolver_file" ]]; then
      printf "  (resolver file MISSING)\n"
    fi

    # Routes check
    networks=()
    while IFS= read -r net; do
      [[ -n "$net" ]] && networks+=("$net")
    done < <(python3 -c "import sys,json; d=json.loads(sys.argv[1]); [print(n) for n in d.get('networks',[])]" "$profile_json")

    if [[ ${#networks[@]} -gt 0 ]]; then
      local svc router
      svc=$(_active_service)
      router=$(_resolve_router "$profile_json")

      printf "\nRoutes (via networksetup, service: %s):\n" "$svc"
      local additional_routes
      additional_routes=$(ns_get_additional_routes "$svc")

      for cidr in "${networks[@]}"; do
        local dest_mask dest
        dest_mask=$(cidr_to_dest_mask "$cidr")
        dest=$(awk '{print $1}' <<< "$dest_mask")
        if echo "$additional_routes" | grep -q "^$dest"; then
          printf "  %-20s -> %-18s [PRESENT]\n" "$cidr" "${router:-?}"
        else
          printf "  %-20s -> %-18s [MISSING]\n" "$cidr" "${router:-?}"
        fi
      done

      # Extra routes in networksetup not in profile
      if [[ -n "$additional_routes" && ! "$additional_routes" =~ "aren't any" ]]; then
        while IFS= read -r line; do
          [[ -z "$line" ]] && continue
          local ar_dest ar_mask ar_gw
          ar_dest=$(awk '{print $1}' <<< "$line")
          ar_mask=$(awk '{print $2}' <<< "$line")
          local found_in_profile=0
          for cidr in "${networks[@]}"; do
            local p_dest_mask p_dest p_mask
            p_dest_mask=$(cidr_to_dest_mask "$cidr")
            p_dest=$(awk '{print $1}' <<< "$p_dest_mask")
            p_mask=$(awk '{print $2}' <<< "$p_dest_mask")
            [[ "$ar_dest" == "$p_dest" && "$ar_mask" == "$p_mask" ]] && { found_in_profile=1; break; }
          done
          if [[ $found_in_profile -eq 0 ]]; then
            ar_gw=$(awk '{print $3}' <<< "$line")
            printf "  %-20s -> %-18s [EXTRA]\n" "$ar_dest/$ar_mask" "$ar_gw"
          fi
        done <<< "$additional_routes"
      fi
    fi

    # DNS test
    if [[ -n "$test_host" ]]; then
      printf "\nDNS test (test_host: %s):\n" "$test_host"
      local resolved
      resolved=$(dscacheutil -q host -a name "$test_host" 2>/dev/null | awk '/ip_address/ {print $2}' | tr '\n' ' ' || true)
      if [[ -n "$resolved" ]]; then
        printf "  [RESOLVED]  %s\n" "$resolved"
      else
        printf "  [FAILED]\n"
      fi
    fi

    # Ping test
    if [[ -n "$ping_host" ]]; then
      printf "\nPing test (ping_host: %s):\n" "$ping_host"
      if ping -c2 -W2 "$ping_host" &>/dev/null; then
        printf "  [REACHABLE]\n"
      else
        printf "  [UNREACHABLE]\n"
      fi
    fi

    printf "\n"
  done
}

# ── action: save ──────────────────────────────────────────────────────────────
do_save() {
  [[ -z "$SAVE_NAME" ]] && { err "--save requires a profile name."; exit 1; }

  # Determine domain to read
  local domain="$SAVE_DOMAIN"
  if [[ -z "$domain" && -f "$ROUTES_FILE" ]]; then
    # Try to load from existing profile
    domain=$(python3 - "$ROUTES_FILE" "$SAVE_NAME" << 'PYEOF' 2>/dev/null || true
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
profiles = data.get("dns", {}).get("profiles", {})
print(profiles.get(sys.argv[2], {}).get("domain", ""))
PYEOF
    )
  fi

  [[ -z "$domain" ]] && { err "No domain specified. Use --domain <domain>."; exit 1; }

  local resolver_file="${RESOLVER_DIR}/${domain}"
  [[ -f "$resolver_file" ]] || { err "Resolver file not found: $resolver_file"; exit 1; }

  # Parse nameservers from the resolver file
  local nameservers=()
  while IFS= read -r line; do
    if [[ "$line" =~ ^nameserver[[:space:]]+(.*) ]]; then
      nameservers+=("${BASH_REMATCH[1]}")
    fi
  done < "$resolver_file"

  [[ ${#nameservers[@]} -eq 0 ]] && { err "No nameserver lines found in $resolver_file"; exit 1; }

  # Optionally gather routes
  info "Found nameservers: ${nameservers[*]}"
  if [[ $ASSUME_YES -eq 0 ]]; then
    info "Would you like to capture current networksetup additional routes for this profile?"
    printf "[y/N] "
    local reply
    read -r reply
  else
    reply="n"
  fi

  local networks_json="[]"
  if [[ "${reply:-n}" =~ ^[Yy]$ ]]; then
    local svc
    svc=$(_active_service)
    local additional_routes
    additional_routes=$(ns_get_additional_routes "$svc")
    if [[ -n "$additional_routes" && ! "$additional_routes" =~ "aren't any" ]]; then
      networks_json=$(python3 - "$additional_routes" << 'PYEOF'
import sys, ipaddress
text = sys.argv[1]
nets = []
for line in text.splitlines():
    parts = line.split()
    if len(parts) >= 2:
        try:
            net = ipaddress.ip_network(f"{parts[0]}/{parts[1]}", strict=False)
            nets.append(str(net))
        except Exception:
            pass
import json
print(json.dumps(nets))
PYEOF
      )
    fi
  fi

  local save_py
  save_py=$(mktemp "${TMPDIR:-/tmp}/dns-save.XXXXXX")

  local ns_json
  ns_json=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1:]))" "${nameservers[@]}")

  cat > "$save_py" << PYEOF
import sys, json, os

routes_file   = sys.argv[1]
profile_name  = sys.argv[2]
domain        = sys.argv[3]
nameservers   = json.loads(sys.argv[4])
networks      = json.loads(sys.argv[5])

# Load or create data
if os.path.exists(routes_file):
    with open(routes_file) as f:
        data = json.load(f)
else:
    data = {}

data.setdefault("dns", {}).setdefault("profiles", {})

existing = data["dns"]["profiles"].get(profile_name, {})
existing["domain"]      = domain
existing["nameservers"] = nameservers
if networks:
    existing["networks"] = networks
data["dns"]["profiles"][profile_name] = existing

os.makedirs(os.path.dirname(os.path.abspath(routes_file)), exist_ok=True)
tmp = routes_file + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, routes_file)
print(f"Saved profile '{profile_name}' to {routes_file}")
PYEOF

  python3 "$save_py" "$ROUTES_FILE" "$SAVE_NAME" "$domain" "$ns_json" "$networks_json"
  rm -f "$save_py"
  ok "Profile '$SAVE_NAME' saved."
}

# ── action: delete ────────────────────────────────────────────────────────────
do_delete() {
  [[ -f "$ROUTES_FILE" ]] || { err "Routes file not found: $ROUTES_FILE"; exit 1; }

  # Check existence before prompting, to avoid hanging confirm on unknown profile
  python3 - "$ROUTES_FILE" "$DELETE_NAME" << 'EXISTCHECK' > /dev/null
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
if sys.argv[2] not in data.get("dns", {}).get("profiles", {}):
    print(f"Profile '{sys.argv[2]}' not found.", file=sys.stderr)
    sys.exit(1)
EXISTCHECK

  confirm "Remove profile '$DELETE_NAME' from $ROUTES_FILE? (no /etc/resolver/ change)"

  local del_py
  del_py=$(mktemp "${TMPDIR:-/tmp}/dns-delete.XXXXXX")

  cat > "$del_py" << PYEOF
import sys, json, os

routes_file  = sys.argv[1]
profile_name = sys.argv[2]

with open(routes_file) as f:
    data = json.load(f)

profiles = data.get("dns", {}).get("profiles", {})
if profile_name not in profiles:
    print(f"Profile '{profile_name}' not found.", file=sys.stderr)
    sys.exit(1)

del profiles[profile_name]

tmp = routes_file + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, routes_file)
print(f"Deleted profile '{profile_name}' from {routes_file}")
PYEOF

  python3 "$del_py" "$ROUTES_FILE" "$DELETE_NAME"
  rm -f "$del_py"
  ok "Profile '$DELETE_NAME' deleted from JSON."
}

# ── action: rename ────────────────────────────────────────────────────────────
do_rename() {
  [[ -f "$ROUTES_FILE" ]] || { err "Routes file not found: $ROUTES_FILE"; exit 1; }

  local ren_py
  ren_py=$(mktemp "${TMPDIR:-/tmp}/dns-rename.XXXXXX")

  cat > "$ren_py" << PYEOF
import sys, json, os

routes_file = sys.argv[1]
old_name    = sys.argv[2]
new_name    = sys.argv[3]

with open(routes_file) as f:
    data = json.load(f)

profiles = data.get("dns", {}).get("profiles", {})
if old_name not in profiles:
    print(f"Profile '{old_name}' not found.", file=sys.stderr)
    sys.exit(1)
if new_name in profiles:
    print(f"Profile '{new_name}' already exists.", file=sys.stderr)
    sys.exit(1)

profiles[new_name] = profiles.pop(old_name)

tmp = routes_file + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, routes_file)
print(f"Renamed '{old_name}' → '{new_name}' in {routes_file}")
PYEOF

  python3 "$ren_py" "$ROUTES_FILE" "$RENAME_OLD" "$RENAME_NEW"
  rm -f "$ren_py"
  ok "Profile renamed."
}

# ── action: backup ────────────────────────────────────────────────────────────
do_backup() {
  local outfile="$BACKUP_PATH"
  if [[ -z "$outfile" ]]; then
    mkdir -p "$ROUTES_BACKUP_DIR"
    outfile="${ROUTES_BACKUP_DIR}/$(date +%Y-%m-%dT%H-%M-%S)-dns.json"
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    info "[DRY-RUN] Would backup /etc/resolver/ to: $outfile"
    return 0
  fi

  local backup_py
  backup_py=$(mktemp "${TMPDIR:-/tmp}/dns-backup.XXXXXX")

  cat > "$backup_py" << 'PYEOF'
import sys, json, os, platform, socket
from datetime import datetime, timezone

outfile     = sys.argv[1]
resolver_dir = sys.argv[2]

resolver_files = {}
if os.path.isdir(resolver_dir):
    for fname in sorted(os.listdir(resolver_dir)):
        fpath = os.path.join(resolver_dir, fname)
        if os.path.isfile(fpath):
            with open(fpath) as f:
                resolver_files[fname] = f.read()

data = {
    "created":        datetime.now(timezone.utc).isoformat(),
    "hostname":       socket.gethostname(),
    "macos_version":  platform.mac_ver()[0],
    "resolver_files": resolver_files,
}

os.makedirs(os.path.dirname(os.path.abspath(outfile)), exist_ok=True)
tmp = outfile + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, outfile)
print(f"Backed up {len(resolver_files)} resolver file(s) to {outfile}")
PYEOF

  python3 "$backup_py" "$outfile" "${RESOLVER_DIR}"
  rm -f "$backup_py"
  ok "DNS backup complete."
}

# ── action: restore ───────────────────────────────────────────────────────────
do_restore() {
  [[ -f "$RESTORE_PATH" ]] || { err "Backup file not found: $RESTORE_PATH"; exit 1; }
  require_root

  confirm "Restore /etc/resolver/ files from $RESTORE_PATH?"

  local restore_py
  restore_py=$(mktemp "${TMPDIR:-/tmp}/dns-restore.XXXXXX")

  cat > "$restore_py" << 'PYEOF'
import sys, json, os

backup_file  = sys.argv[1]
resolver_dir = sys.argv[2]

with open(backup_file) as f:
    data = json.load(f)

files = data.get("resolver_files", {})
if not files:
    print("No resolver_files key in backup.", file=sys.stderr)
    sys.exit(1)

os.makedirs(resolver_dir, exist_ok=True)
for domain, content in files.items():
    dest = os.path.join(resolver_dir, domain)
    tmp  = dest + ".tmp"
    with open(tmp, "w") as f:
        f.write(content)
    os.replace(tmp, dest)
    print(f"Restored: {dest}")

print(f"\nRestored {len(files)} file(s) from {backup_file}")
PYEOF

  python3 "$restore_py" "$RESTORE_PATH" "${RESOLVER_DIR}"
  rm -f "$restore_py"
  info "Flushing DNS cache..."
  flush_dns_cache
  ok "DNS restore complete."
}

# ── action: flush-cache ───────────────────────────────────────────────────────
do_flush_cache() {
  require_root
  info "Flushing DNS cache..."
  flush_dns_cache
  ok "DNS cache flushed."
}

# ── action: test ──────────────────────────────────────────────────────────────
do_test() {
  [[ -f "$ROUTES_FILE" ]] || { err "Routes file not found: $ROUTES_FILE"; exit 1; }

  for name in "${PROFILE_NAMES[@]}"; do
    local profile_json
    profile_json=$(_get_profile_json "$name") || exit 1
    _test_profile "$name" "$profile_json"
  done
}

# ── dispatch ──────────────────────────────────────────────────────────────────
check_macos_version

case "$ACTION" in
  list)         do_list ;;
  show)         do_show ;;
  apply)        do_apply ;;
  remove)       do_remove ;;
  remove-all)   do_remove_all ;;
  diff)         do_diff ;;
  save)         do_save ;;
  delete)       do_delete ;;
  rename)       do_rename ;;
  backup)       do_backup ;;
  restore)      do_restore ;;
  flush-cache)  do_flush_cache ;;
  test)         do_test ;;
  *)            err "Unknown action: $ACTION"; exit 1 ;;
esac

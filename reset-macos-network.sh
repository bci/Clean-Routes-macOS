#!/usr/bin/env zsh
# reset-macos-network.sh — flush routing table, ARP/DNS caches, cycle interfaces,
# restart network services, and optionally capture/restore named route sets.
# Run with: sudo ./reset-macos-network.sh [OPTIONS]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# ── globals ──────────────────────────────────────────────────────────────────
DRY_RUN=0
VERBOSE=0
ASSUME_YES=0
FORCE=0
KEEP_DEFAULT=0
DEFAULT_GATEWAY=""
DEFAULT_IF=""
LIST_ROUTE_MODE=""
FILTER_DEST=""
SHOW_PERSISTENCE=0
BACKUP_FILE=""
RESTORE_FILE=""
FLUSH_STATIC_ONLY=0
FLUSH_DNS_RESOLVERS=0

usage() {
  cat << 'USAGE'
Usage: sudo reset-macos-network.sh [OPTIONS]

Flush macOS routing table, ARP/DNS caches, cycle interfaces, and reset
network services to DHCP.  Optionally list, backup, or restore routes.

Options:
  -v, --verbose              Show each command before executing
  -n, --dry-run              Print actions; do not execute destructive commands
  -f, --force                Bypass SSH guard
  -y, --yes                  Skip confirmation prompt
  --keep-default             Preserve existing default route(s) after flush
  --default-gateway <IP>     Set this IP as the default gateway after flush
  --default-if <iface>       Interface to use when re-adding default route
  -l, --list-routes [ipv4|ipv6]
                             Print routing table and exit (optionally filter AF)
  --ipv4                     Shortcut: list IPv4 routes only
  --ipv6                     Shortcut: list IPv6 routes only
  -F, --filter-dest <pat>    Filter listed routes by dest (prefix, IP, or CIDR)
  -p, --persistence          Annotate routes [PERSISTENT] or [EPHEMERAL]
  --backup [<file>]          Snapshot current routes to JSON before changes
  --restore <file>           Restore routes from a JSON snapshot file and exit
  --flush-static             Delete only static (flag-S) routes and exit
  --flush-dns-resolvers      Delete all /etc/resolver/ files and exit
                             (opt-in only; does NOT run as part of the default reset)
  -h, --help                 Show this help and exit

Examples:
  sudo reset-macos-network.sh -n
  sudo reset-macos-network.sh -y --keep-default
  sudo reset-macos-network.sh -l ipv4 -p -F 172.
  sudo reset-macos-network.sh --backup && sudo reset-macos-network.sh -y
  sudo reset-macos-network.sh --restore ~/.config/macos-routes/backups/2024-01-01.json
USAGE
}

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose)          VERBOSE=1; shift ;;
    -n|--dry-run|--noop)   DRY_RUN=1; shift ;;
    -f|--force)            FORCE=1; shift ;;
    -y|--yes|--assume-yes) ASSUME_YES=1; shift ;;
    --keep-default)        KEEP_DEFAULT=1; shift ;;
    --default-gateway)     DEFAULT_GATEWAY="${2:?--default-gateway requires an IP}"; shift 2 ;;
    --default-if)          DEFAULT_IF="${2:?--default-if requires an interface}"; shift 2 ;;
    -l|--list-routes)
      LIST_ROUTE_MODE="both"
      if [[ "${2:-}" == "ipv4" || "${2:-}" == "ipv6" ]]; then
        LIST_ROUTE_MODE="${2}"; shift
      fi
      shift ;;
    --ipv4)   LIST_ROUTE_MODE="ipv4"; shift ;;
    --ipv6)   LIST_ROUTE_MODE="ipv6"; shift ;;
    -F|--filter-dest)  FILTER_DEST="${2:?--filter-dest requires a pattern}"; shift 2 ;;
    -p|--persistence)  SHOW_PERSISTENCE=1; shift ;;
    --backup)
      if [[ "${2:-}" != "" && "${2:-}" != -* ]]; then
        BACKUP_FILE="$2"; shift 2
      else
        BACKUP_FILE="DEFAULT"; shift
      fi ;;
    --restore)       RESTORE_FILE="${2:?--restore requires a file}"; shift 2 ;;
    --flush-static)  FLUSH_STATIC_ONLY=1; shift ;;
    --flush-dns-resolvers) FLUSH_DNS_RESOLVERS=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

trap 'err "Interrupted by user"; exit 130' INT TERM

# ── list-and-exit (no root required) ─────────────────────────────────────────
_print_routes_and_exit() {
  [[ -z "$LIST_ROUTE_MODE" ]] && return 1

  local routes_tmp filter_tmp
  routes_tmp=$(mktemp "${TMPDIR:-/tmp}/reset-routes.XXXXXX")
  filter_tmp=$(mktemp "${TMPDIR:-/tmp}/reset-routes-filt.XXXXXX")
  trap 'rm -f "$routes_tmp" "$filter_tmp"' RETURN

  case "$LIST_ROUTE_MODE" in
    ipv4) netstat -rn -f inet  > "$routes_tmp" 2>/dev/null || true ;;
    ipv6) netstat -rn -f inet6 > "$routes_tmp" 2>/dev/null || true ;;
    *)    netstat -rn           > "$routes_tmp" 2>/dev/null || true ;;
  esac

  if [[ -n "$FILTER_DEST" ]]; then
    local py_filter
    py_filter=$(make_cidr_filter_script)
    python3 "$py_filter" "$FILTER_DEST" "$routes_tmp" 2 > "$filter_tmp" 2>/dev/null || true
    rm -f "$py_filter"
  else
    cp "$routes_tmp" "$filter_tmp"
  fi

  if [[ $SHOW_PERSISTENCE -eq 0 ]]; then
    cat "$filter_tmp"
    exit 0
  fi

  # Persistence check: only files that contain route-add style commands AND the dest/gw
  local -a persist_locs=(
    /etc /Library/LaunchDaemons /Library/LaunchAgents
    /System/Library/LaunchDaemons /System/Library/LaunchAgents
    /Library/Preferences /var/db
  )
  # add per-user LaunchAgents dirs
  while IFS= read -r d; do
    [[ -n "$d" ]] && persist_locs+=("$d")
  done < <(find /Users -maxdepth 3 -type d -name "LaunchAgents" 2>/dev/null || true)
  [[ -f /etc/rc.local ]] && persist_locs+=(/etc/rc.local)

  _is_persistent() {
    local dest="$1" gw="$2"
    PERSIST_MATCHES=""
    # Only match when dest/gw look like IP addresses
    [[ ! "$dest" =~ [0-9]+\.[0-9] && ! "$dest" =~ ^[0-9a-fA-F:]+/ ]] && return 1
    local loc
    for loc in "${persist_locs[@]}"; do
      [[ -e "$loc" ]] || continue
      # First pass: files that contain a route-adding command
      local candidate_files
      candidate_files=$(grep -RIl --include="*.sh" --include="*.plist" \
        --include="*.conf" --include="*.json" \
        -E "route add|networksetup -setmanual|networksetup -setadditionalroutes|ipconfig set" \
        "$loc" 2>/dev/null || true)
      [[ -z "$candidate_files" ]] && continue
      # Second pass: of those, which also mention the destination?
      local hits
      hits=$(echo "$candidate_files" | xargs grep -l "$dest" 2>/dev/null || true)
      if [[ -n "$hits" ]]; then
        PERSIST_MATCHES="$hits"
        return 0
      fi
    done
    return 1
  }

  local PERSIST_MATCHES=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && { echo; continue; }
    # Header rows pass through unchanged
    if printf '%s' "$line" | grep -qiE '^[[:alpha:]].*:$|^[[:space:]]*(destination|dest|routing|internet)'; then
      echo "$line"; continue
    fi
    local dest gw
    dest=$(awk '{print $1}' <<< "$line")
    gw=$(awk '{print $2}'   <<< "$line")
    if _is_persistent "$dest" "$gw"; then
      printf "%s  [PERSISTENT]\n  -> %s\n" "$line" "$PERSIST_MATCHES"
    else
      printf "%s  [EPHEMERAL]\n" "$line"
    fi
  done < "$filter_tmp"
  exit 0
}

_print_routes_and_exit || true

# ── root required from here ───────────────────────────────────────────────────
require_root

if [[ -n "${SSH_CONNECTION:-}" && $FORCE -ne 1 ]]; then
  err "SSH connection detected. Use --force to override (risk of lockout)."
  exit 2
fi

# ── restore mode ──────────────────────────────────────────────────────────────
if [[ -n "$RESTORE_FILE" ]]; then
  [[ -f "$RESTORE_FILE" ]] || { err "Restore file not found: $RESTORE_FILE"; exit 1; }
  info "Restoring routes from: $RESTORE_FILE"
  confirm "This will add routes from the snapshot. Continue?"

  restore_py=$(mktemp "${TMPDIR:-/tmp}/restore-routes.XXXXXX")
  cat > "$restore_py" << 'RESTORE_PY'
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
for r in data.get("routes", []):
    dest  = r.get("dest", "")
    gw    = r.get("gateway", "")
    iface = r.get("interface", "")
    if not dest or not gw:
        continue
    cmd = f"route -q add {dest} {gw}"
    if iface:
        cmd += f" -interface {iface}"
    print(cmd)
RESTORE_PY

  while IFS= read -r cmd; do
    [[ -z "$cmd" ]] && continue
    run_or_echo "$cmd"
  done < <(python3 "$restore_py" "$RESTORE_FILE")
  rm -f "$restore_py"
  ok "Restore complete."
  exit 0
fi

# ── flush-static mode ─────────────────────────────────────────────────────────
if [[ $FLUSH_STATIC_ONLY -eq 1 ]]; then
  confirm "Delete all static (S-flag) routes?"
  info "Flushing static IPv4 routes..."
  netstat -rn -f inet 2>/dev/null | awk 'NR>3 && $3 ~ /S/ {print $1}' | while read -r dest; do
    run_or_echo "route -q delete $dest 2>/dev/null || true"
  done
  info "Flushing static IPv6 routes..."
  netstat -rn -f inet6 2>/dev/null | awk 'NR>3 && $3 ~ /S/ {print $1}' | while read -r dest; do
    run_or_echo "route -q delete -inet6 $dest 2>/dev/null || true"
  done
  ok "Static routes flushed."
  exit 0
fi

# ── flush-dns-resolvers mode (opt-in only) ──────────────────────────────────
if [[ $FLUSH_DNS_RESOLVERS -eq 1 ]]; then
  confirm "Delete ALL files under /etc/resolver/? This removes conditional DNS resolver configuration, not just the cache."
  info "Flushing /etc/resolver/ files..."
  if [[ -d "/etc/resolver" ]]; then
    find /etc/resolver -maxdepth 1 -type f | while read -r f; do
      run_or_echo "rm -f \"$f\""
    done
  fi
  info "Flushing DNS cache..."
  run_or_echo "dscacheutil -flushcache 2>/dev/null || true"
  run_or_echo "killall -HUP mDNSResponder 2>/dev/null || true"
  ok "Conditional DNS resolver files removed."
  exit 0
fi

# ── optional pre-backup ─────────────────────────────────────────────────────────
if [[ -n "$BACKUP_FILE" ]]; then
  if [[ "$BACKUP_FILE" == "DEFAULT" ]]; then
    mkdir -p "$ROUTES_BACKUP_DIR"
    BACKUP_FILE="${ROUTES_BACKUP_DIR}/$(date +%Y-%m-%dT%H-%M-%S)-pre-reset.json"
  fi
  info "Backing up current routes to: $BACKUP_FILE"
  mkdir -p "$(dirname "$BACKUP_FILE")"

  backup_py=$(mktemp "${TMPDIR:-/tmp}/backup-routes.XXXXXX")
  cat > "$backup_py" << 'BACKUP_PY'
import sys, json, subprocess, platform, socket, os
from datetime import datetime, timezone

out = subprocess.run(["netstat", "-rn"], capture_output=True, text=True).stdout
routes = []
for line in out.splitlines():
    parts = line.split()
    if len(parts) < 2:
        continue
    dest = parts[0]
    if not any(c.isdigit() for c in dest):
        continue
    if dest.lower() in ("destination","dest","internet:","internet6:"):
        continue
    routes.append({
        "dest":      parts[0],
        "gateway":   parts[1] if len(parts) > 1 else "",
        "flags":     parts[2] if len(parts) > 2 else "",
        "interface": parts[-1] if len(parts) > 3 else "",
    })
outfile = sys.argv[1]
data = {
    "created":       datetime.now(timezone.utc).isoformat(),
    "hostname":      socket.gethostname(),
    "macos_version": platform.mac_ver()[0],
    "routes":        routes,
}
tmp = outfile + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, outfile)
print(f"Backed up {len(routes)} routes to {outfile}")
BACKUP_PY

  python3 "$backup_py" "$BACKUP_FILE"
  rm -f "$backup_py"
fi

# ── main destructive flow ─────────────────────────────────────────────────────
check_macos_version
confirm "This will modify network configuration and may disconnect active sessions. Continue?"

# Capture default gateway(s) before flush
DEFAULT_GWS=()
while IFS= read -r gw; do
  [[ -n "$gw" ]] && DEFAULT_GWS+=("$gw")
done < <(netstat -rn | awk '/^default/ {print $2}' | sort -u)

info "Flushing routing table..."
if ! run_or_echo "route -q -n flush"; then
  warn "route -n flush failed; manually deleting non-loopback routes..."
  netstat -rn | awk '$1 ~ /^[0-9]/ && $1 != "127.0.0.1" {print $1, $2}' \
    | while read -r dest gw; do
        run_or_echo "route delete $dest $gw 2>/dev/null || true"
      done
fi

if [[ $KEEP_DEFAULT -eq 1 ]]; then
  for gw in "${DEFAULT_GWS[@]:-}"; do
    [[ -z "$gw" ]] && continue
    info "Restoring default gateway: $gw"
    if [[ -n "$DEFAULT_IF" ]]; then
      run_or_echo "route add default $gw $DEFAULT_IF 2>/dev/null || route add default $gw || true"
    else
      run_or_echo "route add default $gw 2>/dev/null || true"
    fi
  done
fi

if [[ -n "$DEFAULT_GATEWAY" ]]; then
  info "Setting default gateway: $DEFAULT_GATEWAY"
  if [[ -n "$DEFAULT_IF" ]]; then
    run_or_echo "route add default $DEFAULT_GATEWAY $DEFAULT_IF 2>/dev/null \
      || route add default $DEFAULT_GATEWAY || true"
  else
    run_or_echo "route add default $DEFAULT_GATEWAY 2>/dev/null || true"
  fi
fi

info "Flushing ARP cache..."
if [[ $DRY_RUN -eq 1 ]]; then
  printf "[DRY-RUN] arp -d <all entries>\n"
else
  arp -a | awk -F'[()]' '/\(/{print $2}' | while read -r ip; do
    [[ -z "$ip" ]] && continue
    arp -d "$ip" 2>/dev/null || true
    [[ $VERBOSE -eq 1 ]] && info "Deleted ARP: $ip"
  done
fi

info "Flushing DNS cache..."
run_or_echo "dscacheutil -flushcache 2>/dev/null || true"
run_or_echo "killall -HUP mDNSResponder 2>/dev/null || true"

info "Switching network services to DHCP..."
while IFS= read -r svc; do
  [[ -z "$svc" ]] && continue
  info "  DHCP: $svc"
  run_or_echo "networksetup -setdhcp \"$svc\" 2>/dev/null || true"
done < <(ns_list_services)

info "Cycling physical interfaces..."
if [[ $DRY_RUN -eq 1 ]]; then
  printf "[DRY-RUN] ifconfig <iface> down / up / ipconfig set DHCP (skipped)\n"
else
  ifconfig -a | awk -F: '/^[a-z]/{print $1}' \
    | grep -vE '^(lo0|awdl0|bridge0|p2p0|llw0|utun|ipsec)' \
    | while read -r ifc; do
        info "  Cycling: $ifc"
        ifconfig "$ifc" down 2>/dev/null || true
        sleep 0.5
        ifconfig "$ifc" up   2>/dev/null || true
        sleep 0.5
        ipconfig set "$ifc" DHCP 2>/dev/null || true
      done
fi

info "Restarting network daemons..."
run_or_echo "launchctl kickstart -k system/com.apple.mDNSResponder 2>/dev/null || true"
run_or_echo "launchctl kickstart -k system/com.apple.preferences.network 2>/dev/null || true"

info "Scanning startup locations for route-adding scripts..."
SCAN_LOCS=(/etc /Library/LaunchDaemons /Library/LaunchAgents
  /System/Library/LaunchDaemons /System/Library/LaunchAgents
  /Library/Preferences /var/db)
[[ -f /etc/rc.local ]] && SCAN_LOCS+=(/etc/rc.local)

found=0
for loc in "${SCAN_LOCS[@]}"; do
  [[ -e "$loc" ]] || continue
  hits=$(grep -RIn --exclude-dir=.git \
    --include="*.sh" --include="*.plist" --include="*.conf" \
    -E "route add|networksetup -setmanual|networksetup -setadditionalroutes|ipconfig set" \
    "$loc" 2>/dev/null || true)
  if [[ -n "$hits" ]]; then
    warn "Matches in $loc:"
    printf "%s\n" "$hits"
    found=1
  fi
done
[[ $found -eq 0 ]] && ok "No startup scripts found that add routes."

info "Final routing table:"
netstat -rn
ok "Done. Reboot if issues persist."

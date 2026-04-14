#!/usr/bin/env zsh
# watch-macos-routes.sh — poll the routing table and report changes
# Optionally auto-reapply a named route set when routes go missing.
# Usage: ./watch-macos-routes.sh [OPTIONS]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

VERBOSE=0
INTERVAL=5
DO_IPV4=1
DO_IPV6=0
FILTER_PATTERN=""
LOG_FILE=""
RESTORE_SET=""
ROUTES_FILE="${ROUTES_JSON_DEFAULT}"
ONCE=0
WATCH_DNS=0
RESTORE_DNS_NAME=""

ADDED_COUNT=0
REMOVED_COUNT=0
DNS_ADDED_COUNT=0
DNS_REMOVED_COUNT=0

usage() {
  cat << 'USAGE'
Usage: watch-macos-routes.sh [OPTIONS]

Poll the routing table every INTERVAL seconds and print added/removed routes.
Optionally auto-reapply a named set from the JSON routes file when routes go missing.

Options:
  --interval <sec>     Poll interval in seconds (default: 5)
  --ipv4               Watch IPv4 routes (default)
  --ipv6               Watch IPv6 routes
  --all                Watch both IPv4 and IPv6
  --filter <pattern>   Only report changes for routes matching this pattern
  --log <file>         Append change log to this file (ISO timestamp per line)
  --restore-set <name> Auto-reapply this named set when its routes disappear
                       (requires sudo; reads routes from --load file)
  --load <path>        JSON routes file for --restore-set
                       (default: ~/.config/macos-routes/routes.json)
  --once               Run a single diff and exit (no loop)
  --watch-dns          Also poll /etc/resolver/ for additions and removals
  --restore-dns <name> Auto-reapply a named DNS profile when its resolver file
                       disappears (requires sudo if auto-restore fires;
                       reads profile from --load file)
  -v, --verbose        Verbose output
  -h, --help           Show this help

Signals:
  Ctrl-C (INT/TERM)    Print summary and exit cleanly

Examples:
  watch-macos-routes.sh
  watch-macos-routes.sh --interval 10 --ipv6
  watch-macos-routes.sh --restore-set office --interval 30
  watch-macos-routes.sh --once --filter 10.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)    INTERVAL="${2:?--interval requires a number}"; shift 2 ;;
    --ipv4)        DO_IPV4=1; shift ;;
    --ipv6)        DO_IPV6=1; shift ;;
    --all)         DO_IPV4=1; DO_IPV6=1; shift ;;
    --filter)      FILTER_PATTERN="${2:?--filter requires a pattern}"; shift 2 ;;
    --log)         LOG_FILE="${2:?--log requires a file path}"; shift 2 ;;
    --restore-set) RESTORE_SET="${2:?--restore-set requires a set name}"; shift 2 ;;
    --load)        ROUTES_FILE="${2:?--load requires a path}"; shift 2 ;;
    --once)        ONCE=1; shift ;;
    --watch-dns)   WATCH_DNS=1; shift ;;
    --restore-dns) RESTORE_DNS_NAME="${2:?--restore-dns requires a profile name}"; shift 2 ;;
    -v|--verbose)  VERBOSE=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# ── snapshot helper ───────────────────────────────────────────────────────────
_snapshot() {
  if [[ $DO_IPV4 -eq 1 && $DO_IPV6 -eq 1 ]]; then
    netstat -rn 2>/dev/null | awk 'NR>2 {print $1}' | sort -u
  elif [[ $DO_IPV6 -eq 1 ]]; then
    netstat -rn -f inet6 2>/dev/null | awk 'NR>3 {print $1}' | sort -u
  else
    netstat -rn -f inet 2>/dev/null | awk 'NR>3 {print $1}' | sort -u
  fi
}

_matches_filter() {
  local dest="$1"
  [[ -z "$FILTER_PATTERN" ]] && return 0
  [[ "$dest" == *"$FILTER_PATTERN"* ]] && return 0
  return 1
}

_log() {
  local msg="$1"
  if [[ -n "$LOG_FILE" ]]; then
    printf "%s %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >> "$LOG_FILE"
  fi
}

# ── restore set helper ────────────────────────────────────────────────────────
_load_set_routes() {
  # Returns newline-separated list of dest from the named set
  [[ -z "$RESTORE_SET" ]] && return 0
  [[ ! -f "$ROUTES_FILE" ]] && return 0
  python3 - "$ROUTES_FILE" "$RESTORE_SET" << 'PY'
import sys, json
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    routes = data.get("sets", {}).get(sys.argv[2], [])
    for r in routes:
        print(r.get("dest", ""))
except Exception:
    pass
PY
}

_apply_set_route() {
  local dest="$1"
  [[ -z "$RESTORE_SET" || ! -f "$ROUTES_FILE" ]] && return 0
  # Find the gateway for this dest in the set
  local gw iface cmd
  gw=$(python3 - "$ROUTES_FILE" "$RESTORE_SET" "$dest" << 'PY'
import sys, json
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    for r in data.get("sets", {}).get(sys.argv[2], []):
        if r.get("dest") == sys.argv[3]:
            print(r.get("gateway", ""))
            break
except Exception:
    pass
PY
  )
  iface=$(python3 - "$ROUTES_FILE" "$RESTORE_SET" "$dest" << 'PY'
import sys, json
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    for r in data.get("sets", {}).get(sys.argv[2], []):
        if r.get("dest") == sys.argv[3]:
            print(r.get("interface", ""))
            break
except Exception:
    pass
PY
  )
  [[ -z "$gw" ]] && return 0
  cmd="route -q add $dest $gw"
  [[ -n "$iface" ]] && cmd+=" -interface $iface"
  if [[ $EUID -eq 0 ]]; then
    warn "  Auto-restoring: $dest via $gw"
    eval "$cmd" 2>/dev/null || warn "  Failed to restore: $dest"
    _log "AUTO-RESTORED $dest via $gw"
  else
    warn "  [MISSING] $dest — would restore but not root (re-run with sudo for --restore-set)"
  fi
}

# ── DNS snapshot helpers ────────────────────────────────────────────────────────────
_dns_snapshot() {
  # Sorted list of filenames currently under /etc/resolver/
  ls /etc/resolver/ 2>/dev/null | sort || true
}

_restore_dns_profile() {
  local domain="$1"
  [[ -z "$RESTORE_DNS_NAME" ]] && return 0
  [[ ! -f "$ROUTES_FILE" ]] && return 0

  # Look up the profile and check its domain matches
  local profile_domain
  profile_domain=$(python3 - "$ROUTES_FILE" "$RESTORE_DNS_NAME" << 'PY' 2>/dev/null || true
import sys, json
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    profiles = data.get("dns", {}).get("profiles", {})
    print(profiles.get(sys.argv[2], {}).get("domain", ""))
except Exception:
    pass
PY
  )

  [[ "$profile_domain" != "$domain" ]] && return 0

  # Re-apply the resolver file
  local nameservers=() ns
  while IFS= read -r ns; do
    [[ -n "$ns" ]] && nameservers+=("$ns")
  done < <(python3 - "$ROUTES_FILE" "$RESTORE_DNS_NAME" << 'PY' 2>/dev/null || true
import sys, json
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    profiles = data.get("dns", {}).get("profiles", {})
    for ns in profiles.get(sys.argv[2], {}).get("nameservers", []):
        print(ns)
except Exception:
    pass
PY
  )

  [[ ${#nameservers[@]} -eq 0 ]] && return 0

  if [[ $EUID -eq 0 ]]; then
    warn "  [DNS] Auto-restoring: /etc/resolver/$domain for profile '$RESTORE_DNS_NAME'"
    write_resolver_file "$domain" "${nameservers[@]}"
    _log "DNS-RESTORED /etc/resolver/$domain"
  else
    warn "  [DNS MISSING] /etc/resolver/$domain — would restore but not root (re-run with sudo for --restore-dns)"
  fi
}

# ── signal handler ─────────────────────────────────────────────────────────────────
_summarize_and_exit() {
  echo
  info "Watch stopped."
  printf "  Routes added:   %d\n" "$ADDED_COUNT"
  printf "  Routes removed: %d\n" "$REMOVED_COUNT"
  if [[ $WATCH_DNS -eq 1 ]]; then
    printf "  DNS added:      %d\n" "$DNS_ADDED_COUNT"
    printf "  DNS removed:    %d\n" "$DNS_REMOVED_COUNT"
  fi
  exit 0
}
trap '_summarize_and_exit' INT TERM

# ── main loop ─────────────────────────────────────────────────────────────────
check_macos_version

# Load expected routes for restore-set
SET_DESTS=()
if [[ -n "$RESTORE_SET" ]]; then
  while IFS= read -r d; do
    [[ -n "$d" ]] && SET_DESTS+=("$d")
  done < <(_load_set_routes)
  if [[ ${#SET_DESTS[@]} -eq 0 ]]; then
    warn "Set '$RESTORE_SET' not found or empty in $ROUTES_FILE"
  else
    info "Watching for disappearance of ${#SET_DESTS[@]} route(s) in set '$RESTORE_SET'"
  fi
fi

info "Watching routing table (interval=${INTERVAL}s). Press Ctrl-C to stop."
[[ -n "$FILTER_PATTERN" ]] && info "Filter: $FILTER_PATTERN"
[[ $WATCH_DNS -eq 1 ]] && info "Also watching /etc/resolver/ for DNS changes."
if [[ -n "$RESTORE_DNS_NAME" ]]; then
  info "Auto-restore DNS profile: $RESTORE_DNS_NAME"
fi

prev_snapshot=$(mktemp "${TMPDIR:-/tmp}/watch-prev.XXXXXX")
curr_snapshot=$(mktemp "${TMPDIR:-/tmp}/watch-curr.XXXXXX")
prev_dns_snapshot=$(mktemp "${TMPDIR:-/tmp}/watch-dns-prev.XXXXXX")
curr_dns_snapshot=$(mktemp "${TMPDIR:-/tmp}/watch-dns-curr.XXXXXX")
trap 'rm -f "$prev_snapshot" "$curr_snapshot" "$prev_dns_snapshot" "$curr_dns_snapshot"; _summarize_and_exit' INT TERM

# Initial snapshots
_snapshot > "$prev_snapshot"
if [[ $WATCH_DNS -eq 1 ]]; then
  _dns_snapshot > "$prev_dns_snapshot"
fi

if [[ $ONCE -eq 1 ]]; then
  sleep "$INTERVAL"
  _snapshot > "$curr_snapshot"

  # Added routes
  comm -13 "$prev_snapshot" "$curr_snapshot" | while read -r dest; do
    _matches_filter "$dest" || continue
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf "%s  \033[1;32m[ADDED]\033[0m   %s\n" "$ts" "$dest"
    _log "ADDED $dest"
    ADDED_COUNT=$(( ADDED_COUNT + 1 ))
  done

  # Removed routes
  comm -23 "$prev_snapshot" "$curr_snapshot" | while read -r dest; do
    _matches_filter "$dest" || continue
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf "%s  \033[1;31m[REMOVED]\033[0m %s\n" "$ts" "$dest"
    _log "REMOVED $dest"
    REMOVED_COUNT=$(( REMOVED_COUNT + 1 ))
    _apply_set_route "$dest"
  done

  # DNS diff (--once)
  if [[ $WATCH_DNS -eq 1 ]]; then
    _dns_snapshot > "$curr_dns_snapshot"
    comm -13 "$prev_dns_snapshot" "$curr_dns_snapshot" | while read -r fname; do
      [[ -z "$fname" ]] && continue
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      printf "%s  \033[1;32m[DNS ADDED]\033[0m   /etc/resolver/%s\n" "$ts" "$fname"
      _log "DNS ADDED /etc/resolver/$fname"
      DNS_ADDED_COUNT=$(( DNS_ADDED_COUNT + 1 ))
    done
    comm -23 "$prev_dns_snapshot" "$curr_dns_snapshot" | while read -r fname; do
      [[ -z "$fname" ]] && continue
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      printf "%s  \033[1;31m[DNS REMOVED]\033[0m /etc/resolver/%s\n" "$ts" "$fname"
      _log "DNS REMOVED /etc/resolver/$fname"
      DNS_REMOVED_COUNT=$(( DNS_REMOVED_COUNT + 1 ))
      _restore_dns_profile "$fname"
    done
  fi

  rm -f "$prev_snapshot" "$curr_snapshot" "$prev_dns_snapshot" "$curr_dns_snapshot"
  exit 0
fi

while true; do
  sleep "$INTERVAL"
  _snapshot > "$curr_snapshot"

  # Detect added routes
  while IFS= read -r dest; do
    [[ -z "$dest" ]] && continue
    _matches_filter "$dest" || continue
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf "%s  \033[1;32m[ADDED]\033[0m   %s\n" "$ts" "$dest"
    _log "ADDED $dest"
    ADDED_COUNT=$(( ADDED_COUNT + 1 ))
  done < <(comm -13 "$prev_snapshot" "$curr_snapshot" 2>/dev/null || true)

  # Detect removed routes
  while IFS= read -r dest; do
    [[ -z "$dest" ]] && continue
    _matches_filter "$dest" || continue
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf "%s  \033[1;31m[REMOVED]\033[0m %s\n" "$ts" "$dest"
    _log "REMOVED $dest"
    REMOVED_COUNT=$(( REMOVED_COUNT + 1 ))
    # Auto-restore if this dest is in our watched set
    if [[ ${#SET_DESTS[@]} -gt 0 ]]; then
      found=0
      for sd in "${SET_DESTS[@]}"; do
        [[ "$sd" == "$dest" ]] && { found=1; break; }
      done
      [[ $found -eq 1 ]] && _apply_set_route "$dest"
    fi
  done < <(comm -23 "$prev_snapshot" "$curr_snapshot" 2>/dev/null || true)

  # DNS change detection
  if [[ $WATCH_DNS -eq 1 ]]; then
    _dns_snapshot > "$curr_dns_snapshot"

    while IFS= read -r fname; do
      [[ -z "$fname" ]] && continue
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      printf "%s  \033[1;32m[DNS ADDED]\033[0m   /etc/resolver/%s\n" "$ts" "$fname"
      _log "DNS ADDED /etc/resolver/$fname"
      DNS_ADDED_COUNT=$(( DNS_ADDED_COUNT + 1 ))
    done < <(comm -13 "$prev_dns_snapshot" "$curr_dns_snapshot" 2>/dev/null || true)

    while IFS= read -r fname; do
      [[ -z "$fname" ]] && continue
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      printf "%s  \033[1;31m[DNS REMOVED]\033[0m /etc/resolver/%s\n" "$ts" "$fname"
      _log "DNS REMOVED /etc/resolver/$fname"
      DNS_REMOVED_COUNT=$(( DNS_REMOVED_COUNT + 1 ))
      _restore_dns_profile "$fname"
    done < <(comm -23 "$prev_dns_snapshot" "$curr_dns_snapshot" 2>/dev/null || true)

    cp "$curr_dns_snapshot" "$prev_dns_snapshot"
  fi

  cp "$curr_snapshot" "$prev_snapshot"
done

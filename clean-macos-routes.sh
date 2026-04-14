#!/usr/bin/env zsh
# clean-macos-routes.sh — list and remove static macOS routes
# Supports IPv4, IPv6, CIDR filtering, persistence updates, backup/restore.
# Run as root (sudo) for deletion and persistence operations.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DRY_RUN=0
VERBOSE=0
ASSUME_YES=0

FILTER=""
NETWORKS=()   # multi-value --network
DO_IPV4=1
DO_IPV6=0
PERSIST=0
UNINSTALL=0
PRUNE_BACKUPS=0
PRUNE_KEEP=10
RESTORE_TS=""
BACKUP_DIR="/var/tmp/clean_static_routes_backups"

usage() {
  cat << 'USAGE'
Usage: clean-macos-routes.sh [OPTIONS]

List and remove static macOS routes (S-flag in netstat).

Options:
  --dry-run                  Show actions; do not make changes
  --yes                      Act without prompting
  --filter <pattern>         Grep-style filter on destination/gateway/line
  --network <CIDR>           Remove routes overlapping this CIDR (repeatable)
  --ipv6                     Also process IPv6 static routes
  --all                      Process both IPv4 and IPv6
  --persist                  Remove routes from networksetup additional-routes
                             (requires sudo; backs up first)
  --uninstall-persist        Restore the most-recent backup
  --restore <ts>             Restore a specific backup by timestamp prefix
  --prune-backups [N]        Delete oldest backups, keep N (default 10)
  -n, --dry-run              Alias for --dry-run
  -y, --yes                  Alias for --yes
  -v, --verbose              Show commands before running
  -h, --help                 Show this help

Examples:
  sudo clean-macos-routes.sh --dry-run --network 172.16.0.0/12
  sudo clean-macos-routes.sh --network 172.16.0.0/12 --persist
  sudo clean-macos-routes.sh --uninstall-persist
  sudo clean-macos-routes.sh --prune-backups 5
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|-n)         DRY_RUN=1; shift ;;
    --yes|-y)             ASSUME_YES=1; shift ;;
    -v|--verbose)         VERBOSE=1; shift ;;
    --filter)             FILTER="${2:?--filter requires a pattern}"; shift 2 ;;
    --network)            NETWORKS+=("${2:?--network requires a CIDR}"); shift 2 ;;
    --ipv6)               DO_IPV6=1; shift ;;
    --all)                DO_IPV4=1; DO_IPV6=1; shift ;;
    --persist)            PERSIST=1; shift ;;
    --uninstall-persist)  UNINSTALL=1; shift ;;
    --restore)            RESTORE_TS="${2:?--restore requires a timestamp}"; shift 2 ;;
    --prune-backups)
      PRUNE_BACKUPS=1
      if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
        PRUNE_KEEP="$2"; shift 2
      else
        shift
      fi ;;
    -h|--help)            usage; exit 0 ;;
    *) err "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

# ── helpers ───────────────────────────────────────────────────────────────────
_cidr_match_py() {
  local network="$1" candidate="$2"
  python3 - "$network" "$candidate" << 'PY'
import sys, ipaddress
net_str, cand = sys.argv[1], sys.argv[2]
try:
    net = ipaddress.ip_network(net_str, strict=False)
except Exception:
    sys.exit(2)
try:
    if '/' in cand:
        r = ipaddress.ip_network(cand, strict=False)
        sys.exit(0 if (net.overlaps(r) or r.subnet_of(net)) else 1)
    else:
        a = ipaddress.ip_address(cand)
        sys.exit(0 if a in net else 1)
except Exception:
    sys.exit(1)
PY
}

_networks_match() {
  local candidate="$1"
  [[ ${#NETWORKS[@]} -eq 0 ]] && return 0   # no --network filter → match all
  local net
  for net in "${NETWORKS[@]}"; do
    if _cidr_match_py "$net" "$candidate" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# ── prune backups ─────────────────────────────────────────────────────────────
if [[ $PRUNE_BACKUPS -eq 1 ]]; then
  if [[ ! -d "$BACKUP_DIR" ]]; then
    info "No backup directory found: $BACKUP_DIR"
    exit 0
  fi
  # Backups are subdirs named by timestamp; sort oldest first
  all_backups=()
  while IFS= read -r d; do
    all_backups+=("$d")
  done < <(ls -1dt "$BACKUP_DIR"/* 2>/dev/null | tail -r || true)
  count="${#all_backups[@]}"
  if (( count <= PRUNE_KEEP )); then
    info "Only $count backup(s) found; nothing to prune (keep=$PRUNE_KEEP)."
    exit 0
  fi
  to_delete=$(( count - PRUNE_KEEP ))
  info "Pruning $to_delete of $count backup(s)..."
  for d in "${all_backups[@]:0:$to_delete}"; do
    run_or_echo "rm -rf \"$d\""
  done
  ok "Prune complete."
  exit 0
fi

# ── restore / uninstall ───────────────────────────────────────────────────────
_do_restore() {
  local backup_path="$1"
  info "Restoring from: $backup_path"
  confirm "Will call networksetup (requires sudo). Continue?"
  for f in "$backup_path"/*; do
    [[ -f "$f" ]] || continue
    local svc_line svc routes
    svc_line=$(head -n1 "$f" || true)
    svc="${svc_line#\# service: }"
    routes=$(tail -n +2 "$f" | sed '/^$/d' || true)
    if [[ -z "$routes" ]]; then
      info "Clearing all additional routes for: $svc"
      run_or_echo "networksetup -setadditionalroutes \"$svc\""
    else
      info "Restoring routes for: $svc"
      local -a args=()
      while IFS= read -r r; do
        local rd rm rgw
        read -r rd rm rgw <<< "$r"
        args+=("$rd" "$rm" "$rgw")
      done <<< "$routes"
      run_or_echo "networksetup -setadditionalroutes \"$svc\" ${args[*]}"
    fi
  done
  ok "Restore complete."
}

if [[ -n "$RESTORE_TS" ]]; then
  found_dir=$(ls -1d "$BACKUP_DIR"/${RESTORE_TS}* 2>/dev/null | head -n1 || true)
  [[ -z "$found_dir" ]] && { err "No backup matching timestamp: $RESTORE_TS"; exit 1; }
  _do_restore "$found_dir"
  exit 0
fi

if [[ $UNINSTALL -eq 1 ]]; then
  latest=$(ls -1dt "$BACKUP_DIR"/* 2>/dev/null | head -n1 || true)
  if [[ -z "$latest" ]]; then
    info "No backups found in $BACKUP_DIR. Nothing to restore."
    exit 0
  fi
  _do_restore "$latest"
  exit 0
fi

# ── gather static routes ──────────────────────────────────────────────────────
info "Gathering static routes..."

declare -a raw_routes=()

_collect_static() {
  local af_flag="$1"
  while IFS= read -r l; do
    raw_routes+=("$l")
  done < <(netstat -rn "$af_flag" 2>/dev/null | awk 'NR>3 && $3 ~ /S/ {print $0}')
}

[[ $DO_IPV4 -eq 1 ]] && _collect_static "-f inet"
[[ $DO_IPV6 -eq 1 ]] && _collect_static "-f inet6"

if [[ ${#raw_routes[@]} -eq 0 ]]; then
  info "No static routes found."
  exit 0
fi

# ── process each route ────────────────────────────────────────────────────────
declare -a deleted_routes=()

for line in "${raw_routes[@]}"; do
  dest=''
  gateway=''
  netflag=''
  gw_opt=''

  dest=$(awk '{print $1}'    <<< "$line")
  gateway=$(awk '{print $2}' <<< "$line")

  # Apply --filter
  if [[ -n "$FILTER" ]]; then
    grep -qi -- "$FILTER" <<< "$line" || continue
  fi

  # Apply --network
  check="$dest"
  if [[ "$dest" == "default" || "$dest" == "*" || "$dest" == link#* ]]; then
    check="$gateway"
  fi
  _networks_match "$check" || continue

  # Build delete command
  netflag=""
  [[ "$dest" == */* || "$dest" =~ \.0$ ]] && netflag="-net"

  gw_opt=""
  if [[ "$gateway" != link#* && "$gateway" != "*" ]]; then
    gw_opt="$gateway"
  fi

  del_cmd="route delete"
  [[ -n "$netflag" ]] && del_cmd+=" $netflag"
  del_cmd+=" $dest"
  [[ -n "$gw_opt" ]] && del_cmd+=" $gw_opt"

  printf "Found:  %s\n" "$line"
  printf "Delete: %s\n\n" "$del_cmd"

  if [[ $DRY_RUN -eq 1 ]]; then
    printf "  (dry-run) not executing\n\n"
    continue
  fi

  if [[ $ASSUME_YES -eq 0 ]]; then
    printf "Delete this route? [y/N/q] "
    ans=''
    read -r ans
    case "$ans" in
      [yY]|[yY][eE][sS]) ;;
      [qQ]) info "Quitting."; exit 0 ;;
      *) info "Skipping."; continue ;;
    esac
  fi

  eval "$del_cmd" && deleted_routes+=("${dest}|${gw_opt}")
  [[ $VERBOSE -eq 1 ]] && ok "Deleted: $dest"
done

if [[ ${#deleted_routes[@]} -eq 0 ]]; then
  info "No routes deleted."
  [[ $PERSIST -eq 0 ]] && exit 0
fi

# ── persist (networksetup additional routes) ──────────────────────────────────
if [[ $PERSIST -eq 1 && ${#deleted_routes[@]} -gt 0 ]]; then
  info "Updating persistent additional routes for ${#deleted_routes[@]} deleted route(s)..."
  confirm "Apply persistent removals via networksetup? (requires sudo)"

  if ! command -v networksetup >/dev/null 2>&1; then
    err "networksetup not available"; exit 1
  fi

  ts=$(date +%Y%m%dT%H%M%S)
  backup_path="${BACKUP_DIR}/${ts}"
  mkdir -p "$backup_path"
  info "Backing up existing per-service routes to: $backup_path"

  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    svc=$(sed 's/^ *//;s/ *$//' <<< "$svc")
    routes_raw=$(ns_get_additional_routes "$svc")
    if [[ -z "$routes_raw" || "$routes_raw" =~ "aren't any" ]]; then
      continue
    fi
    san=$(sed 's/ /_/g; s/\//_ /g' <<< "$svc")
    printf "# service: %s\n%s\n" "$svc" "$routes_raw" > "${backup_path}/${san}.routes"

    remaining=() to_remove=()
    while IFS= read -r r; do
      [[ -z "$r" ]] && continue
      rd='' rm='' rgw=''
      read -r rd rm rgw <<< "$r"
      remove=0

      if [[ ${#NETWORKS[@]} -gt 0 ]]; then
        for net in "${NETWORKS[@]}"; do
          _cidr_match_py "$net" "${rd}/${rm}" 2>/dev/null && { remove=1; break; } || true
        done
      else
        for t in "${deleted_routes[@]}"; do
          td='' tg=''
          IFS='|' read -r td tg <<< "$t"
          if [[ "$td" == "$rd" || ( -n "$tg" && "$tg" == "$rgw" ) ]]; then
            remove=1; break
          fi
        done
      fi

      if [[ $remove -eq 1 ]]; then
        to_remove+=("$rd $rm $rgw")
      else
        remaining+=("$rd $rm $rgw")
      fi
    done <<< "$routes_raw"

    if [[ ${#to_remove[@]} -gt 0 ]]; then
      info "Service $svc — removing ${#to_remove[@]} route(s)"
      if [[ $DRY_RUN -eq 1 ]]; then
        printf "[DRY-RUN] would update networksetup for: %s\n" "$svc"
      else
        if [[ ${#remaining[@]} -eq 0 ]]; then
          run_or_echo "networksetup -setadditionalroutes \"$svc\""
        else
          ns_args=()
          for rr in "${remaining[@]}"; do
            rd='' rm='' rg=''
            read -r rd rm rg <<< "$rr"
            ns_args+=("$rd" "$rm" "$rg")
          done
          run_or_echo "networksetup -setadditionalroutes \"$svc\" ${ns_args[*]}"
        fi
      fi
    fi
  done < <(ns_list_services)

  ok "Persistent update complete. Backup: $backup_path"
fi

ok "All done."

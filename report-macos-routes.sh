#!/usr/bin/env zsh
# report-macos-routes.sh — snapshot report of all routes and conditional DNS
#
# Prints a human-readable summary of:
#   • /etc/resolver/ conditional DNS entries
#   • networksetup additional routes (all services)
#   • kernel routing table (IPv4 gateway/tunnel routes only)
#
# No root required. No state changes.
# Usage: ./report-macos-routes.sh [--no-color] [--routes-json <file>]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

ROUTES_JSON="${HOME}/.config/macos-routes/routes.json"

# ── arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --no-color)        export NO_COLOR=1; shift ;;
    --routes-json)     ROUTES_JSON="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: report-macos-routes.sh [--no-color] [--routes-json <file>]"
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── colour primitives ─────────────────────────────────────────────────────────
_c() {
  # _c CODE text — wrap text in ANSI colour if colour is enabled
  if _use_color; then printf "\033[%sm%s\033[0m" "$1" "$2"
  else printf "%s" "$2"
  fi
}
_bold()   { _c "1"     "$*"; }
_cyan()   { _c "1;36"  "$*"; }
_green()  { _c "1;32"  "$*"; }
_yellow() { _c "1;33"  "$*"; }
_red()    { _c "1;31"  "$*"; }
_dim()    { _c "2"     "$*"; }

# ── layout helpers ────────────────────────────────────────────────────────────
W=62  # inner content width (between border chars)

_rule() {
  # _rule [char] — full-width horizontal rule
  local ch="${1:-─}"
  printf "%${W}s\n" "" | tr ' ' "$ch"
}

_header() {
  _rule "═"
  printf " $(_bold "$*")\n"
  _rule "═"
}

_section() {
  echo
  printf "$(_cyan "▌") $(_bold "$*")\n"
  _rule "─"
}

_kv() {
  # _kv label value [status]
  local label="$1" value="$2" status="${3:-}"
  local labw=22
  printf "  %-${labw}s %s" "$label" "$value"
  if [[ -n "$status" ]]; then
    case "$status" in
      OK)       printf "  %s" "$(_green   "[  OK  ]")" ;;
      WARN)     printf "  %s" "$(_yellow  "[ WARN ]")" ;;
      MISSING)  printf "  %s" "$(_red     "[MISSING]")" ;;
      EXTRA)    printf "  %s" "$(_yellow  "[ EXTRA ]")" ;;
      SKIPPED)  printf "  %s" "$(_dim     "[SKIPPED]")" ;;
    esac
  fi
  echo
}

_blank_label() { printf "  %-22s %s\n" "" "$*"; }

# ── known profile networks (from routes.json) ─────────────────────────────────
# Returns newline-separated "dest/mask" strings for all configured profiles.
_all_profile_networks() {
  [[ -f "$ROUTES_JSON" ]] || return 0
  python3 - "$ROUTES_JSON" << 'PYEOF'
import sys, json, ipaddress
with open(sys.argv[1]) as f:
    data = json.load(f)
for p in data.get("dns", {}).get("profiles", {}).values():
    for cidr in p.get("networks", []):
        net = ipaddress.ip_network(cidr, strict=False)
        print(f"{net.network_address} {net.netmask}")
PYEOF
}

# ── report ────────────────────────────────────────────────────────────────────

_header " Network Report — $(date '+%a %b %d %H:%M:%S %Z %Y')"

# ══ 1. Conditional DNS ═══════════════════════════════════════════════════════
_section "Conditional DNS  (/etc/resolver/)"

resolver_count=0
if [[ -d /etc/resolver ]]; then
  for f in /etc/resolver/*; do
    [[ -f "$f" ]] || continue
    (( resolver_count++ )) || true
    domain="${f##*/}"
    printf "\n  $(_bold "$domain")\n"
    while IFS= read -r line; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      key="${line%% *}"
      val="${line#* }"
      _blank_label "$(_dim "$key")  $val"
    done < "$f"
  done
fi
if [[ $resolver_count -eq 0 ]]; then
  printf "  $(_dim "(none — no files in /etc/resolver/)")\n"
fi

# ══ 2. networksetup Additional Routes ════════════════════════════════════════
_section "Static Routes  (networksetup, all services)"

# Build set of known profile dest+mask pairs for EXTRA detection
known_routes=()
while IFS= read -r line; do
  [[ -n "$line" ]] && known_routes+=("$line")
done < <(_all_profile_networks)

any_svc_routes=0
while IFS= read -r svc; do
  [[ -z "$svc" ]] && continue
  raw=$(networksetup -getadditionalroutes "$svc" 2>/dev/null || true)
  # strip "There are no…" lines
  routes=$(echo "$raw" | grep -v "There are no" | grep -v "^$" || true)
  [[ -z "$routes" ]] && continue
  any_svc_routes=1
  printf "\n  $(_bold "$svc")\n"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    dest=$(awk '{print $1}' <<< "$line")
    mask=$(awk '{print $2}' <<< "$line")
    gw=$(awk '{print $3}'   <<< "$line")
    # Determine if this is a known configured route or an extra
    status="EXTRA"
    for known in "${known_routes[@]}"; do
      k_dest="${known%% *}"
      k_mask="${known##* }"
      if [[ "$dest" == "$k_dest" && "$mask" == "$k_mask" ]]; then
        status="OK"; break
      fi
    done
    # Format as CIDR for readability
    cidr=$(python3 -c "
import ipaddress, sys
try:
  n=ipaddress.IPv4Network(f'{sys.argv[1]}/{sys.argv[2]}',strict=False)
  print(str(n))
except: print(f'{sys.argv[1]}/{sys.argv[2]}')
" "$dest" "$mask" 2>/dev/null || echo "$dest/$mask")
    _kv "  $cidr" "→ $gw" "$status"
  done <<< "$routes"
done < <(ns_list_services)

if [[ $any_svc_routes -eq 0 ]]; then
  printf "  $(_dim "(none — no additional routes on any service)")\n"
fi

# ══ 3. Kernel Routing Table ═══════════════════════════════════════════════════
_section "Kernel Routing Table  (IPv4, gateway/tunnel entries)"

printf "\n  %-32s %-22s %s\n" "$(_dim "Destination")" "$(_dim "Gateway")" "$(_dim "Interface")"
printf "  %s  %s  %s\n" "$(printf '%.0s─' {1..30})" "$(printf '%.0s─' {1..20})" "$(printf '%.0s─' {1..12})"

# macOS netstat -rn columns: Destination Gateway Flags Netif [Expire]
netstat -rn -f inet 2>/dev/null \
  | awk '/^Routing|^Internet|^Destination|^$/{next} {print $1, $2, $3, $4}' \
  | while read -r dest gw flags netif; do
  # Skip loopback entries
  [[ "$dest" == 127* ]] && continue
  [[ "$netif" == "lo0" && "$dest" != "default" ]] && continue
  # Skip link-layer ARP/NDP entries on non-tunnel interfaces
  [[ "$gw" == link#* ]] && [[ "$netif" != utun* && "$netif" != ppp* && "$netif" != ipsec* ]] && continue
  # Skip multicast / link-local / broadcast noise
  [[ "$dest" == 224.* || "$dest" == 169.254* || "$dest" == 255.* ]] && continue
  # Skip per-host ARP cache entries on LAN (MAC address gateways)
  [[ "$gw" =~ ^[0-9a-f]{1,2}:[0-9a-f]{1,2}: ]] && continue
  # Skip the redundant "default via tunnel link" — the routed gateway entry is enough
  [[ "$dest" == "default" && "$gw" == link#* ]] && continue
  # Skip intra-tunnel host routes (UHWIi flags) — they're VPN housekeeping, not user-relevant
  [[ "$flags" == *W* && "$netif" == utun* && "$dest" != "$gw" ]] && continue

  # Raw label (no colour) for column width calculation
  raw_dest="$dest"

  # Colour destination by type
  if   [[ "$dest" == "default" ]];       then label="$(_yellow "$dest")"
  elif [[ "$netif" == utun* || "$netif" == ppp* || "$netif" == ipsec* ]]; then
                                               label="$(_green  "$dest")"
  elif [[ "$dest" == 192.168* || "$dest" == 10.* \
       || "$dest" == 172.1[6-9]* || "$dest" == 172.2[0-9]* || "$dest" == 172.3[01]* ]]; then
                                               label="$(_cyan   "$dest")"
  else                                         label="$dest"
  fi

  # Colour gateway
  if   [[ "$gw" == link#* ]];   then gw_label="$(_dim "(direct)")"
  else                               gw_label="$gw"
  fi

  # Pad based on raw (non-ANSI) length to keep columns aligned
  pad=$(( 30 - ${#raw_dest} ))
  (( pad < 1 )) && pad=1
  printf "  %s%${pad}s  %-20s  %s\n" "$label" "" "$gw_label" "$netif"
done

# ══ 4. Active VPN Tunnels ═════════════════════════════════════════════════════
_section "VPN / Tunnel Interfaces"

tunnel_count=0
for iface in $(ifconfig -l 2>/dev/null); do
  [[ "$iface" == utun* || "$iface" == ppp* || "$iface" == ipsec* ]] || continue
  ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet / && !/127\./{print $2}')
  [[ -z "$ip" ]] && continue
  (( tunnel_count++ )) || true
  mtu=$(ifconfig "$iface" 2>/dev/null | awk '/mtu/{print $NF}')
  printf "  $(_green "%-12s") %-20s %s\n" "$iface" "$ip" "$(_dim "mtu $mtu")"
done
if [[ $tunnel_count -eq 0 ]]; then
  printf "  $(_dim "(no active tunnel interfaces)")\n"
fi

# ══ footer ════════════════════════════════════════════════════════════════════
echo
_rule "═"
printf " $(_dim "routes.json: ${ROUTES_JSON}")\n"
_rule "═"
echo

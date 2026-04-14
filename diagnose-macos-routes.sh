#!/usr/bin/env zsh
# diagnose-macos-routes.sh — read-only network route diagnostics for macOS
# No root required; no state changes.
# Usage: ./diagnose-macos-routes.sh [OPTIONS]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

VERBOSE=0
DO_IPV4=1
DO_IPV6=0
JSON_OUTPUT=0
CHECK_GATEWAY=0

usage() {
  cat << 'USAGE'
Usage: diagnose-macos-routes.sh [OPTIONS]

Read-only network diagnostics: routing table, DNS, VPN interfaces, ARP,
static routes, and networksetup additional routes.

Options:
  --ipv4          IPv4 routing table (default)
  --ipv6          IPv6 routing table
  --all           Both IPv4 and IPv6
  --check-gateway Ping each default gateway (1 packet)
  --json          Emit a single JSON object to stdout
  -v, --verbose   Verbose output
  -h, --help      Show this help

No root required. No state changes are made.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ipv4)          DO_IPV4=1; shift ;;
    --ipv6)          DO_IPV6=1; shift ;;
    --all)           DO_IPV4=1; DO_IPV6=1; shift ;;
    --check-gateway) CHECK_GATEWAY=1; shift ;;
    --json)          JSON_OUTPUT=1; shift ;;
    -v|--verbose)    VERBOSE=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# ── collect data ──────────────────────────────────────────────────────────────

_sys_info() {
  sw_vers 2>/dev/null || true
  echo "Hostname: $(hostname)"
  echo "Date:     $(date)"
}

_routing_table() {
  if [[ $DO_IPV4 -eq 1 ]]; then
    echo "── IPv4 Routing Table ─────────────────────────────"
    netstat -rn -f inet 2>/dev/null || true
  fi
  if [[ $DO_IPV6 -eq 1 ]]; then
    echo "── IPv6 Routing Table ─────────────────────────────"
    netstat -rn -f inet6 2>/dev/null || true
  fi
}

_default_gateways() {
  local -a gws=()
  while IFS= read -r gw; do
    [[ -n "$gw" ]] && gws+=("$gw")
  done < <(netstat -rn | awk '/^default/ {print $2}' | sort -u)
  printf '%s\n' "${gws[@]:-}"
}

_ping_gateway() {
  local gw="$1"
  if ping -c1 -W1 "$gw" &>/dev/null; then
    ok "  Gateway $gw is reachable"
  else
    warn "  Gateway $gw is NOT reachable"
  fi
}

_dns_info() {
  scutil --dns 2>/dev/null | head -40 || true
}

_vpn_interfaces() {
  ifconfig 2>/dev/null \
    | awk '/^(utun|ppp|ipsec)[0-9]/{iface=$1; next} iface{print iface, $0; iface=""}' \
    | head -40 || true
  # Simpler: just list VPN-like interface names
  ifconfig -a 2>/dev/null | awk -F: '/^(utun|ppp|ipsec)[0-9]/{print $1}' || true
}

_arp_summary() {
  arp -a 2>/dev/null | head -30 || true
}

_conditional_dns() {
  local resolver_dir="/etc/resolver"
  if [[ ! -d "$resolver_dir" ]] || [[ -z "$(ls "$resolver_dir/" 2>/dev/null)" ]]; then
    echo "  (none configured)"
    return 0
  fi
  for f in "$resolver_dir"/*; do
    [[ -f "$f" ]] || continue
    local domain
    domain=$(basename "$f")
    printf "  %s\n" "$domain"
    sed 's/^/    /' "$f"
  done
}

_static_routes() {
  echo "── Static IPv4 (S-flag) ───────────────────────────"
  netstat -rn -f inet 2>/dev/null | awk 'NR>3 && $3 ~ /S/ {print $0}' || true
  if [[ $DO_IPV6 -eq 1 ]]; then
    echo "── Static IPv6 (S-flag) ───────────────────────────"
    netstat -rn -f inet6 2>/dev/null | awk 'NR>3 && $3 ~ /S/ {print $0}' || true
  fi
}

_additional_routes() {
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    local r
    r=$(ns_get_additional_routes "$svc")
    if [[ -n "$r" && ! "$r" =~ "aren't any" ]]; then
      echo "  Service: $svc"
      echo "$r" | sed 's/^/    /'
    fi
  done < <(ns_list_services)
}

# ── JSON mode ─────────────────────────────────────────────────────────────────
if [[ $JSON_OUTPUT -eq 1 ]]; then
  # Write all data to temp files, then build JSON with python3
  tmp_rt4=$(mktemp "${TMPDIR:-/tmp}/diag-rt4.XXXXXX")
  tmp_rt6=$(mktemp "${TMPDIR:-/tmp}/diag-rt6.XXXXXX")
  tmp_dns=$(mktemp "${TMPDIR:-/tmp}/diag-dns.XXXXXX")
  tmp_arp=$(mktemp "${TMPDIR:-/tmp}/diag-arp.XXXXXX")
  tmp_st=$(mktemp  "${TMPDIR:-/tmp}/diag-st.XXXXXX")
  tmp_ar=$(mktemp  "${TMPDIR:-/tmp}/diag-ar.XXXXXX")
  tmp_gw=$(mktemp  "${TMPDIR:-/tmp}/diag-gw.XXXXXX")
  trap 'rm -f "$tmp_rt4" "$tmp_rt6" "$tmp_dns" "$tmp_arp" "$tmp_st" "$tmp_ar" "$tmp_gw"' EXIT

  netstat -rn -f inet  > "$tmp_rt4" 2>/dev/null || true
  netstat -rn -f inet6 > "$tmp_rt6" 2>/dev/null || true
  scutil --dns          > "$tmp_dns" 2>/dev/null || true
  arp -a                > "$tmp_arp" 2>/dev/null || true
  netstat -rn -f inet 2>/dev/null | awk 'NR>3 && $3 ~ /S/' > "$tmp_st" || true
  _additional_routes    > "$tmp_ar"  2>/dev/null || true
  _default_gateways     > "$tmp_gw"  2>/dev/null || true

  json_py=$(mktemp "${TMPDIR:-/tmp}/diag-json.XXXXXX")
  cat > "$json_py" << 'JSONPY'
import sys, json, platform, socket, subprocess, os
from datetime import datetime, timezone

def slurp(path):
    try:
        with open(path) as f:
            return f.read()
    except Exception:
        return ""

def parse_routes(text):
    routes = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 2 or not any(c.isdigit() for c in parts[0]):
            continue
        if parts[0].lower() in ("destination","dest"):
            continue
        routes.append({
            "dest":      parts[0],
            "gateway":   parts[1] if len(parts) > 1 else "",
            "flags":     parts[2] if len(parts) > 2 else "",
            "interface": parts[-1] if len(parts) > 3 else "",
        })
    return routes

def read_resolver_files(resolver_dir="/etc/resolver"):
    result = {}
    if not os.path.isdir(resolver_dir):
        return result
    for fname in sorted(os.listdir(resolver_dir)):
        fpath = os.path.join(resolver_dir, fname)
        if os.path.isfile(fpath):
            try:
                with open(fpath) as f:
                    result[fname] = f.read()
            except Exception:
                pass
    return result

rt4_file, rt6_file, dns_file, arp_file, st_file, ar_file, gw_file = sys.argv[1:]

static = parse_routes(slurp(st_file))
gateways = [l.strip() for l in slurp(gw_file).splitlines() if l.strip()]

vpn_ifaces = []
try:
    out = subprocess.run(["ifconfig", "-a"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        name = line.split(":")[0]
        if name.startswith(("utun", "ppp", "ipsec")):
            vpn_ifaces.append(name)
except Exception:
    pass

result = {
    "created":       datetime.now(timezone.utc).isoformat(),
    "hostname":      socket.gethostname(),
    "macos_version": platform.mac_ver()[0],
    "default_gateways": gateways,
    "routing_table_v4": parse_routes(slurp(rt4_file)),
    "routing_table_v6": parse_routes(slurp(rt6_file)),
    "static_routes":    static,
    "vpn_interfaces":   vpn_ifaces,
    "dns_config":       slurp(dns_file),
    "arp_table":        slurp(arp_file),
    "additional_routes": slurp(ar_file),
    "conditional_dns":  read_resolver_files(),
}
print(json.dumps(result, indent=2))
JSONPY

  python3 "$json_py" \
    "$tmp_rt4" "$tmp_rt6" "$tmp_dns" "$tmp_arp" "$tmp_st" "$tmp_ar" "$tmp_gw"
  rm -f "$json_py"
  exit 0
fi

# ── human-readable mode ───────────────────────────────────────────────────────
check_macos_version

echo "════════════════════════════════════════════════════"
echo " macOS Route Diagnostics"
echo "════════════════════════════════════════════════════"
_sys_info
echo

echo "── Default Gateways ───────────────────────────────"
gws=()
while IFS= read -r gw; do
  [[ -n "$gw" ]] && gws+=("$gw")
done < <(_default_gateways)

if [[ ${#gws[@]} -eq 0 ]]; then
  warn "No default gateways found."
else
  printf '  %s\n' "${gws[@]}"
  if [[ $CHECK_GATEWAY -eq 1 ]]; then
    for gw in "${gws[@]}"; do
      _ping_gateway "$gw"
    done
  fi
fi
echo

echo "── Routing Table ──────────────────────────────────"
_routing_table
echo

echo "── Static Routes (S-flag) ─────────────────────────"
_static_routes
echo

echo "── DNS Configuration ──────────────────────────────"
_dns_info
echo

echo "── VPN Interfaces ─────────────────────────────────"
vpn_out=$(_vpn_interfaces)
if [[ -z "$vpn_out" ]]; then
  echo "  (none detected)"
else
  echo "$vpn_out"
fi
echo

echo "── ARP Table (first 30 entries) ───────────────────"
_arp_summary
echo

echo "── Conditional DNS (/etc/resolver/) ───────────────"
_conditional_dns
echo

echo "── networksetup Additional Routes ─────────────────"
ar_out=$(_additional_routes)
if [[ -z "$ar_out" ]]; then
  echo "  (none configured)"
else
  echo "$ar_out"
fi
echo
ok "Diagnostics complete."

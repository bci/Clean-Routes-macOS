#!/usr/bin/env zsh
# lib/common.sh — shared helpers for macos-routes scripts
# Source this file; do not execute directly.
# Usage: source "$(dirname "$0")/lib/common.sh"

# ---------------------------------------------------------------------------
# Colour / output helpers
# Respect NO_COLOR env var and non-TTY stdout
# ---------------------------------------------------------------------------
_use_color() {
  [[ -z "${NO_COLOR:-}" && -t 1 ]]
}

info() {
  if _use_color; then
    printf "\033[1;34m[INFO]\033[0m %s\n" "$*"
  else
    printf "[INFO] %s\n" "$*"
  fi
}

warn() {
  if _use_color; then
    printf "\033[1;33m[WARN]\033[0m %s\n" "$*" >&2
  else
    printf "[WARN] %s\n" "$*" >&2
  fi
}

err() {
  if _use_color; then
    printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2
  else
    printf "[ERROR] %s\n" "$*" >&2
  fi
}

ok() {
  if _use_color; then
    printf "\033[1;32m[ OK ]\033[0m %s\n" "$*"
  else
    printf "[ OK ] %s\n" "$*"
  fi
}

# ---------------------------------------------------------------------------
# Dry-run / verbose command wrapper
# Globals: DRY_RUN, VERBOSE (both default 0 if unset)
# ---------------------------------------------------------------------------
run_or_echo() {
  local dry="${DRY_RUN:-0}"
  local verbose="${VERBOSE:-0}"
  if [[ $dry -eq 1 ]]; then
    printf "[DRY-RUN] %s\n" "$*"
    return 0
  fi
  if [[ $verbose -eq 1 ]]; then
    printf "[EXEC] %s\n" "$*"
  fi
  eval "$*"
}

# ---------------------------------------------------------------------------
# Root guard
# ---------------------------------------------------------------------------
require_root() {
  [[ ${DRY_RUN:-0} -eq 1 ]] && return 0
  if [[ $EUID -ne 0 ]]; then
    err "This operation requires root. Re-run with sudo."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# networksetup wrappers — all calls go through these so tests can mock them
# and so we get a consistent timeout on slow/hung interfaces.
# ---------------------------------------------------------------------------

# List all active network services (strips header line and disabled entries).
ns_list_services() {
  command -v networksetup >/dev/null 2>&1 || return 0
  networksetup -listallnetworkservices 2>/dev/null | sed '1d;/^\*/d'
}

# Get additional routes for a service (returns empty string on error).
ns_get_additional_routes() {
  local svc="$1"
  command -v networksetup >/dev/null 2>&1 || return 0
  networksetup -getadditionalroutes "$svc" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Interactive confirm (defaults to No)
# Skipped when DRY_RUN=1 or ASSUME_YES=1
# ---------------------------------------------------------------------------
confirm() {
  local prompt="${1:-Continue?}"
  if [[ "${DRY_RUN:-0}" -eq 1 || "${ASSUME_YES:-0}" -eq 1 ]]; then
    return 0
  fi
  printf "%s [y/N] " "$prompt"
  local reply
  read -r reply
  if [[ ! $reply =~ ^[Yy]$ ]]; then
    info "Aborted."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# macOS version guard
# Warn on versions older than Ventura (13)
# ---------------------------------------------------------------------------
check_macos_version() {
  local ver
  ver=$(sw_vers -productVersion 2>/dev/null || echo "0")
  local major
  major=$(echo "$ver" | cut -d. -f1)
  if [[ $major -lt 13 ]]; then
    warn "macOS $ver detected. These scripts are tested on Ventura (13) and later."
    warn "Some networksetup/route behaviours may differ on older releases."
  fi
}

# ---------------------------------------------------------------------------
# Python3 CIDR helper — writes a temp script, prints its path.
# Caller must rm the file.  Usage:
#   py=$(make_cidr_filter_script)
#   python3 "$py" <pattern> <routes-file> [header_lines_to_skip]
#   rm -f "$py"
# ---------------------------------------------------------------------------
make_cidr_filter_script() {
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/mr-cidr.XXXXXX")
  cat > "$tmp" << 'PYEOF'
import sys, ipaddress, re

pattern = sys.argv[1].strip()
routes_file = sys.argv[2]
skip = int(sys.argv[3]) if len(sys.argv) > 3 else 0

def is_octet_mask(p):
    return bool(re.match(r'^\d{1,3}/\d{1,2}$', p))

def matches(dest, pat):
    if not pat:
        return True
    # dot-prefix like '172.'
    if pat.endswith('.') and pat != '.':
        return dest.startswith(pat)
    # shorthand like '10/24'
    if is_octet_mask(pat):
        octet, mask = pat.split('/')
        if '/' in dest:
            if dest.endswith('/' + mask) and (dest.startswith(octet + '.') or dest.startswith(octet + '/')):
                return True
        try:
            net = ipaddress.ip_network(dest, strict=False)
            return net.prefixlen == int(mask) and net.network_address.packed[0] == int(octet)
        except Exception:
            return pat in dest
        return False
    # full CIDR / IP
    try:
        pat_net = ipaddress.ip_network(pat, strict=False)
    except Exception:
        return pat in dest
    try:
        d_net = ipaddress.ip_network(dest, strict=False)
        if pat_net.version != d_net.version:
            return False
        return pat_net.subnet_of(d_net) or pat_net.overlaps(d_net)
    except Exception:
        return pat in dest

with open(routes_file) as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    if i < skip:
        print(line, end='')
        continue
    parts = line.split()
    if not parts:
        print(line, end='')
        continue
    dest = parts[0]
    if dest.lower() in ('destination', 'dest', 'routing', 'internet:',
                        'internet6:', 'internet', 'internet6'):
        print(line, end='')
        continue
    if matches(dest, pattern):
        print(line, end='')
PYEOF
  printf '%s' "$tmp"
}

# ---------------------------------------------------------------------------
# Gather static IPv4 routes from netstat (flag S present)
# Prints lines: dest gateway flags interface
# ---------------------------------------------------------------------------
get_static_routes_v4() {
  netstat -rn -f inet 2>/dev/null | awk 'NR>3 && $3 ~ /S/ {print $0}'
}

get_static_routes_v6() {
  netstat -rn -f inet6 2>/dev/null | awk 'NR>3 && $3 ~ /S/ {print $0}'
}

# ---------------------------------------------------------------------------
# Default config dir
# ---------------------------------------------------------------------------
ROUTES_CONFIG_DIR="${HOME}/.config/macos-routes"
ROUTES_JSON_DEFAULT="${ROUTES_CONFIG_DIR}/routes.json"
ROUTES_BACKUP_DIR="${ROUTES_CONFIG_DIR}/backups"
RESOLVER_DIR="/etc/resolver"

# ---------------------------------------------------------------------------
# DNS helpers
# ---------------------------------------------------------------------------

# Flush macOS DNS cache
flush_dns_cache() {
  run_or_echo "dscacheutil -flushcache 2>/dev/null || true"
  run_or_echo "killall -HUP mDNSResponder 2>/dev/null || true"
}

# Write a single /etc/resolver/<domain> file atomically.
# Usage: write_resolver_file <domain> <nameserver1> [<nameserver2> ...]
write_resolver_file() {
  local domain="$1"; shift
  local resolver_file="${RESOLVER_DIR}/${domain}"
  local tmp="${resolver_file}.tmp"
  mkdir -p "${RESOLVER_DIR}"
  {
    for ns in "$@"; do
      printf "nameserver %s\n" "$ns"
    done
    printf "domain %s\n" "$domain"
  } > "$tmp"
  mv "$tmp" "$resolver_file"
}

# Remove a /etc/resolver/<domain> file if it exists.
remove_resolver_file() {
  local domain="$1"
  local resolver_file="${RESOLVER_DIR}/${domain}"
  if [[ -f "$resolver_file" ]]; then
    run_or_echo "rm -f \"$resolver_file\""
  fi
}

# List all filenames (not paths) under /etc/resolver/
list_resolver_files() {
  ls "${RESOLVER_DIR}/" 2>/dev/null || true
}

# cidr_to_dest_mask <CIDR> — prints "network_addr netmask" via python3.
# Example: cidr_to_dest_mask 172.16.0.0/12 → 172.16.0.0 255.240.0.0
cidr_to_dest_mask() {
  python3 -c "
import ipaddress, sys
net = ipaddress.ip_network(sys.argv[1], strict=False)
print(net.network_address, net.netmask)
" "$1"
}

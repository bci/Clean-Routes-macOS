#!/usr/bin/env zsh
# backup-restore-routes.sh — JSON snapshot, restore, diff, and prune for macOS routes
# Backup does NOT require root. Restore requires root.
# Usage: ./backup-restore-routes.sh [OPTIONS]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DRY_RUN=0
VERBOSE=0
ASSUME_YES=0

ACTION=""
BACKUP_PATH=""
RESTORE_PATH=""
DIFF_PATH=""
LIST_BACKUPS=0
PRUNE_KEEP=10
INCLUDE_DNS=0
LIST_DNS=0

usage() {
  cat << 'USAGE'
Usage: backup-restore-routes.sh [OPTIONS]

Snapshot, restore, diff, and prune macOS route backups (JSON format).

JSON format:
  {
    "created":       "ISO8601",
    "hostname":      "...",
    "macos_version": "...",
    "routes": [
      {"dest":"...","gateway":"...","flags":"...","interface":"..."}
    ],
    "additional_routes": {
      "<service>": [{"dest":"...","mask":"...","gateway":"..."}]
    }
  }

Options:
  --backup [<file>]     Snapshot current routes to <file>
                        Default: ~/.config/macos-routes/backups/<timestamp>.json
  --restore <file>      Restore routes from a snapshot (requires sudo)
  --list-backups        List all backups in the default directory
  --diff <file>         Compare a snapshot against the current routing table
                        Prints [MISSING], [PRESENT], [EXTRA] per route
  --prune [N]           Delete oldest backups, keep N (default: 10)
  --include-dns         Include /etc/resolver/ files in --backup or --restore
  --list-dns            Include Conditional DNS section in --diff output
  -n, --dry-run         Print commands; do not execute
  -y, --yes             Skip confirmation prompts
  -v, --verbose         Show commands before running
  -h, --help            Show this help

Examples:
  backup-restore-routes.sh --backup
  backup-restore-routes.sh --backup ~/Desktop/routes-pre-vpn.json
  backup-restore-routes.sh --list-backups
  sudo backup-restore-routes.sh --restore ~/.config/macos-routes/backups/2024-01-01T12-00-00.json
  backup-restore-routes.sh --diff ~/.config/macos-routes/backups/2024-01-01T12-00-00.json
  backup-restore-routes.sh --prune 5
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --list-backups)
      ACTION="list"; shift ;;
    --diff)
      ACTION="diff"
      DIFF_PATH="${2:?--diff requires a file}"; shift 2 ;;
    --prune)
      ACTION="prune"
      if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
        PRUNE_KEEP="$2"; shift 2
      else
        shift
      fi ;;
    --include-dns) INCLUDE_DNS=1; shift ;;
    --list-dns)    LIST_DNS=1; shift ;;
    -n|--dry-run)  DRY_RUN=1; shift ;;
    -y|--yes)      ASSUME_YES=1; shift ;;
    -v|--verbose)  VERBOSE=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "$ACTION" ]]; then
  err "No action specified."
  usage
  exit 1
fi

# ── python3 backup helper ─────────────────────────────────────────────────────
_write_backup_py() {
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/br-backup.XXXXXX")
  cat > "$tmp" << 'PYEOF'
import sys, json, subprocess, platform, socket, os
from datetime import datetime, timezone

outfile     = sys.argv[1]
include_dns = sys.argv[2] == "1"

def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout

def parse_netstat(text):
    routes = []
    for line in text.splitlines():
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
    return routes

def parse_additional(svc_name):
    out = run(["networksetup", "-getadditionalroutes", svc_name])
    if not out.strip() or "aren't any" in out:
        return []
    results = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3:
            results.append({"dest": parts[0], "mask": parts[1], "gateway": parts[2]})
    return results

# Gather routes
routes = parse_netstat(run(["netstat", "-rn"]))

# Gather networksetup additional routes
additional = {}
try:
    svc_out = run(["networksetup", "-listallnetworkservices"])
    for svc in svc_out.splitlines()[1:]:
        svc = svc.lstrip("*").strip()
        if not svc:
            continue
        ar = parse_additional(svc)
        if ar:
            additional[svc] = ar
except Exception:
    pass

# Gather /etc/resolver/ files if requested
resolver_files = {}
if include_dns:
    resolver_dir = "/etc/resolver"
    if os.path.isdir(resolver_dir):
        for fname in sorted(os.listdir(resolver_dir)):
            fpath = os.path.join(resolver_dir, fname)
            if os.path.isfile(fpath):
                try:
                    with open(fpath) as f:
                        resolver_files[fname] = f.read()
                except Exception:
                    pass

data = {
    "created":           datetime.now(timezone.utc).isoformat(),
    "hostname":          socket.gethostname(),
    "macos_version":     platform.mac_ver()[0],
    "routes":            routes,
    "additional_routes": additional,
}
if include_dns:
    data["resolver_files"] = resolver_files

tmp = outfile + ".tmp"
os.makedirs(os.path.dirname(os.path.abspath(outfile)), exist_ok=True)
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, outfile)
dns_msg = f" + {len(resolver_files)} resolver file(s)" if include_dns else ""
print(f"Backed up {len(routes)} routes + {sum(len(v) for v in additional.values())} additional routes{dns_msg}")
print(f"File: {outfile}")
PYEOF
  printf '%s' "$tmp"
}

# ── python3 diff helper ───────────────────────────────────────────────────────
_write_diff_py() {
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/br-diff.XXXXXX")
  cat > "$tmp" << 'PYEOF'
import sys, json, subprocess, ipaddress

backup_file = sys.argv[1]

def normalise(dest):
    """Normalise a route destination for comparison."""
    try:
        return str(ipaddress.ip_network(dest, strict=False))
    except Exception:
        return dest.lower()

# Load backup
with open(backup_file) as f:
    data = json.load(f)

backup_routes = {normalise(r["dest"]): r for r in data.get("routes", [])}

# Current routing table
out = subprocess.run(["netstat", "-rn"], capture_output=True, text=True).stdout
current_dests = set()
for line in out.splitlines():
    parts = line.split()
    if not parts:
        continue
    dest = parts[0]
    if not any(c.isdigit() for c in dest):
        continue
    if dest.lower() in ("destination","dest","internet:","internet6:"):
        continue
    current_dests.add(normalise(dest))

print(f"\nComparing backup ({data.get('created','?')}) vs current routing table:\n")
missing  = [d for d in backup_routes if d not in current_dests]
present  = [d for d in backup_routes if d in current_dests]
extra    = [d for d in current_dests if d not in backup_routes]

for d in sorted(present):
    r = backup_routes[d]
    print(f"  [PRESENT]  {r['dest']}  ->  {r.get('gateway','')}")
for d in sorted(missing):
    r = backup_routes[d]
    print(f"  [MISSING]  {r['dest']}  ->  {r.get('gateway','')}")
for d in sorted(extra):
    print(f"  [EXTRA]    {d}")

print(f"\nSummary: {len(present)} present, {len(missing)} missing, {len(extra)} extra")
PYEOF
  printf '%s' "$tmp"
}

# ── actions ───────────────────────────────────────────────────────────────────

do_backup() {
  local outfile="$BACKUP_PATH"
  if [[ -z "$outfile" ]]; then
    mkdir -p "$ROUTES_BACKUP_DIR"
    outfile="${ROUTES_BACKUP_DIR}/$(date +%Y-%m-%dT%H-%M-%S).json"
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    info "[DRY-RUN] Would backup routes to: $outfile"
    return 0
  fi

  local py
  py=$(_write_backup_py)
  python3 "$py" "$outfile" "$INCLUDE_DNS"
  rm -f "$py"
}

do_restore() {
  [[ -f "$RESTORE_PATH" ]] || { err "File not found: $RESTORE_PATH"; exit 1; }
  require_root
  info "Restoring routes from: $RESTORE_PATH"
  confirm "This will add routes from the snapshot. Some may already exist. Continue?"

  local restore_py
  restore_py=$(mktemp "${TMPDIR:-/tmp}/br-restore.XXXXXX")
  cat > "$restore_py" << 'RESTORE_PY'
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)

print("# Routes")
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

print("# Additional routes")
for svc, routes in data.get("additional_routes", {}).items():
    if not routes:
        continue
    args = " ".join(f'"{r["dest"]}" "{r["mask"]}" "{r["gateway"]}"' for r in routes)
    print(f'networksetup -setadditionalroutes "{svc}" {args}')
RESTORE_PY

  local cmds
  cmds=$(python3 "$restore_py" "$RESTORE_PATH")
  rm -f "$restore_py"

  while IFS= read -r cmd; do
    [[ -z "$cmd" || "$cmd" == '#'* ]] && continue
    run_or_echo "$cmd"
  done <<< "$cmds"

  # Restore /etc/resolver/ files if --include-dns and backup contains them
  if [[ $INCLUDE_DNS -eq 1 ]]; then
    local dns_restore_py
    dns_restore_py=$(mktemp "${TMPDIR:-/tmp}/br-dns-restore.XXXXXX")
    trap 'rm -f "$dns_restore_py"' RETURN
    cat > "$dns_restore_py" << 'DNSRESTORE_PY'
import sys, json, os

backup_file  = sys.argv[1]
resolver_dir = "/etc/resolver"

with open(backup_file) as f:
    data = json.load(f)

files = data.get("resolver_files", {})
if not files:
    print("  (no resolver_files in this backup)")
    sys.exit(0)

os.makedirs(resolver_dir, exist_ok=True)
for domain, content in files.items():
    dest = os.path.join(resolver_dir, domain)
    tmp  = dest + ".tmp"
    with open(tmp, "w") as f:
        f.write(content)
    os.replace(tmp, dest)
    print(f"  Restored: {dest}")
print(f"  Restored {len(files)} resolver file(s)")
DNSRESTORE_PY
    info "Restoring /etc/resolver/ files..."
    python3 "$dns_restore_py" "$RESTORE_PATH"
    rm -f "$dns_restore_py"
  fi

  ok "Restore complete."
}

do_list() {
  if [[ ! -d "$ROUTES_BACKUP_DIR" ]]; then
    info "No backup directory found: $ROUTES_BACKUP_DIR"
    exit 0
  fi
  info "Backups in $ROUTES_BACKUP_DIR:"
  local count=0
  while IFS= read -r f; do
    local ts size
    ts=$(basename "$f" .json)
    size=$(wc -c < "$f" | tr -d ' ')
    printf "  %s  (%s bytes)\n" "$ts" "$size"
    count=$(( count + 1 ))
  done < <(ls -1t "$ROUTES_BACKUP_DIR"/*.json 2>/dev/null || echo -n "")
  if [[ $count -eq 0 ]]; then info "  (none found)"; fi
}

do_diff() {
  [[ -f "$DIFF_PATH" ]] || { err "File not found: $DIFF_PATH"; exit 1; }
  local py
  py=$(_write_diff_py)
  python3 "$py" "$DIFF_PATH"
  rm -f "$py"

  # DNS diff section
  if [[ $LIST_DNS -eq 1 ]]; then
    local dns_diff_py
    dns_diff_py=$(mktemp "${TMPDIR:-/tmp}/br-dns-diff.XXXXXX")
    trap 'rm -f "$dns_diff_py"' RETURN
    cat > "$dns_diff_py" << 'DNSDIFF_PY'
import sys, json, os

backup_file  = sys.argv[1]
resolver_dir = "/etc/resolver"

with open(backup_file) as f:
    data = json.load(f)

backup_files = data.get("resolver_files", {})
if not backup_files:
    print("\nConditional DNS: (no resolver_files in backup)")
    sys.exit(0)

print("\nConditional DNS (/etc/resolver/) diff:")
print()

live_files = {}
if os.path.isdir(resolver_dir):
    for fname in sorted(os.listdir(resolver_dir)):
        fpath = os.path.join(resolver_dir, fname)
        if os.path.isfile(fpath):
            try:
                with open(fpath) as f:
                    live_files[fname] = f.read()
            except Exception:
                pass

all_domains = sorted(set(backup_files) | set(live_files))
for domain in all_domains:
    in_backup = domain in backup_files
    in_live   = domain in live_files
    if in_backup and in_live:
        b_content = backup_files[domain].strip()
        l_content = live_files[domain].strip()
        status = "MATCH" if b_content == l_content else "CHANGED"
        print(f"  [{status}]   {domain}")
    elif in_backup and not in_live:
        print(f"  [MISSING]  {domain}  (in backup, not in live)")
    else:
        print(f"  [EXTRA]    {domain}  (in live, not in backup)")

print()
print(f"  Backup has {len(backup_files)} file(s), live has {len(live_files)} file(s)")
DNSDIFF_PY
    python3 "$dns_diff_py" "$DIFF_PATH"
    rm -f "$dns_diff_py"
  fi
}

do_prune() {
  if [[ ! -d "$ROUTES_BACKUP_DIR" ]]; then
    info "No backup directory: $ROUTES_BACKUP_DIR"
    exit 0
  fi

  # Filenames are ISO timestamps so lexicographic sort = chronological
  local -a all_files=()
  while IFS= read -r f; do
    all_files+=("$f")
  done < <(ls -1 "$ROUTES_BACKUP_DIR"/*.json 2>/dev/null | sort || true)

  local count="${#all_files[@]}"
  if (( count <= PRUNE_KEEP )); then
    info "Only $count backup(s); nothing to prune (keep=$PRUNE_KEEP)."
    exit 0
  fi

  local to_delete=$(( count - PRUNE_KEEP ))
  info "Pruning $to_delete of $count backup(s)..."
  confirm "Delete $to_delete oldest backup(s)?"

  for f in "${all_files[@]:0:$to_delete}"; do
    run_or_echo "rm -f \"$f\""
    [[ $VERBOSE -eq 1 ]] && info "Deleted: $f"
  done
  ok "Prune complete. Kept $PRUNE_KEEP backup(s)."
}

# ── dispatch ──────────────────────────────────────────────────────────────────
check_macos_version

case "$ACTION" in
  backup)  do_backup ;;
  restore) do_restore ;;
  list)    do_list ;;
  diff)    do_diff ;;
  prune)   do_prune ;;
  *)       err "Unknown action: $ACTION"; exit 1 ;;
esac

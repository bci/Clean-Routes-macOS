#!/usr/bin/env zsh
# add-macos-routes.sh — manage named route sets stored in a JSON file
# Requires: bash 5+, macOS, python3, sudo (for --apply / --reset-all)
# Usage: add-macos-routes.sh [OPTIONS]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DRY_RUN=0
VERBOSE=0
ASSUME_YES=0

# ── defaults ─────────────────────────────────────────────────────────────────
ROUTES_FILE="${ROUTES_JSON_DEFAULT}"
FILTER_IPV4=0
FILTER_IPV6=0

usage() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Manage named static-route sets stored in a JSON file.

JSON format:
  {
    "sets": {
      "<name>": [
        { "dest": "10.0.0.0/8", "gateway": "192.168.1.1" },
        { "dest": "172.16.0.0/12", "gateway": "10.0.0.1", "interface": "en0" }
      ]
    }
  }

Options:
  --load <path>          Use <path> instead of the default JSON file
                         (default: ${ROUTES_JSON_DEFAULT})
  --list                 List available set names and exit
  --show                 Print all sets with their routes and exit
  --apply <name> [...]   Apply one or more named sets (adds routes)
  --reset-all            Delete ALL current static routes before --apply
  --save <name>          Save current static routes into a set named <name>
  --delete <name>        Remove a named set from the JSON file
  --rename <old> <new>   Rename a set
  --diff <name>          Show which routes in <name> are missing / present
  --ipv4                 Operate on IPv4 routes only
  --ipv6                 Operate on IPv6 routes only
  -n, --dry-run          Print commands without executing
  -v, --verbose          Print each command before running
  -y, --yes              Skip confirmation prompts
  -h, --help             Show this help and exit

Examples:
  $(basename "$0") --list
  $(basename "$0") --apply office vpn
  $(basename "$0") --reset-all --apply office
  $(basename "$0") --save my-current-routes
  $(basename "$0") --diff office
EOF
}

# ── arg parsing ──────────────────────────────────────────────────────────────
ACTION=""
ACTION_NAMES=()
SAVE_NAME=""
DELETE_NAME=""
RENAME_OLD=""
RENAME_NEW=""
DIFF_NAME=""
RESET_ALL=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --load)       ROUTES_FILE="${2:?--load requires a path}"; shift 2 ;;
    --list)       ACTION="list"; shift ;;
    --show)       ACTION="show"; shift ;;
    --apply)
      ACTION="apply"
      shift
      while [[ $# -gt 0 && $1 != -* ]]; do
        ACTION_NAMES+=("$1"); shift
      done
      ;;
    --reset-all)  RESET_ALL=1; shift ;;
    --save)       ACTION="save"; SAVE_NAME="${2:?--save requires a name}"; shift 2 ;;
    --delete)     ACTION="delete"; DELETE_NAME="${2:?--delete requires a name}"; shift 2 ;;
    --rename)
      ACTION="rename"
      RENAME_OLD="${2:?--rename requires old name}"; shift 2
      RENAME_NEW="${1:?--rename requires new name}"; shift
      ;;
    --diff)       ACTION="diff"; DIFF_NAME="${2:?--diff requires a name}"; shift 2 ;;
    --ipv4)       FILTER_IPV4=1; shift ;;
    --ipv6)       FILTER_IPV6=1; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -y|--yes)     ASSUME_YES=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [[ -z $ACTION ]]; then
  err "No action specified."
  usage
  exit 1
fi

# Conflict check
if [[ $ACTION == "apply" && -n $SAVE_NAME ]]; then
  err "--save and --apply cannot be used together."
  exit 1
fi

# ── python3 helpers ──────────────────────────────────────────────────────────
# All JSON manipulation is done via a single mktemp Python script to avoid
# any heredoc-under-sudo issues.

_write_py_helper() {
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/add-routes.XXXXXX")
  cat > "$tmp" << 'PYEOF'
import sys, json, os, tempfile

action   = sys.argv[1]
jfile    = sys.argv[2]
args     = sys.argv[3:]

def load():
    if not os.path.exists(jfile):
        return {"sets": {}}
    with open(jfile) as f:
        return json.load(f)

def save(data):
    tmp = jfile + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, jfile)

if action == "list":
    data = load()
    for name in sorted(data.get("sets", {})):
        print(name)

elif action == "show":
    data = load()
    for name, routes in sorted(data.get("sets", {}).items()):
        print(f"\n=== {name} ===")
        for r in routes:
            iface = f" via {r['interface']}" if r.get("interface") else ""
            print(f"  {r['dest']}  ->  {r['gateway']}{iface}")

elif action == "get":
    name = args[0]
    data = load()
    routes = data.get("sets", {}).get(name)
    if routes is None:
        print(f"ERROR: set '{name}' not found", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(routes))

elif action == "save":
    name = args[0]
    # remaining args: alternating dest gateway [interface|-] pairs
    routes = []
    i = 0
    while i < len(args) - 1:
        i += 1  # skip "name"
        break
    pairs = args[1:]
    i = 0
    while i + 1 < len(pairs):
        dest    = pairs[i]
        gateway = pairs[i+1]
        iface   = pairs[i+2] if i+2 < len(pairs) and pairs[i+2] not in ("--", "") else None
        entry = {"dest": dest, "gateway": gateway}
        if iface and iface != "-":
            entry["interface"] = iface
        routes.append(entry)
        i += 3 if iface is not None else 2
    data = load()
    data.setdefault("sets", {})[name] = routes
    save(data)
    print(f"Saved {len(routes)} route(s) into set '{name}'")

elif action == "delete":
    name = args[0]
    data = load()
    if name not in data.get("sets", {}):
        print(f"ERROR: set '{name}' not found", file=sys.stderr)
        sys.exit(1)
    del data["sets"][name]
    save(data)
    print(f"Deleted set '{name}'")

elif action == "rename":
    old, new = args[0], args[1]
    data = load()
    if old not in data.get("sets", {}):
        print(f"ERROR: set '{old}' not found", file=sys.stderr)
        sys.exit(1)
    data["sets"][new] = data["sets"].pop(old)
    save(data)
    print(f"Renamed '{old}' -> '{new}'")

elif action == "diff":
    name = args[0]
    # args[1:] = current route destinations (one per line via xargs)
    data = load()
    routes = data.get("sets", {}).get(name)
    if routes is None:
        print(f"ERROR: set '{name}' not found", file=sys.stderr)
        sys.exit(1)
    current = set(args[1:])
    for r in routes:
        dest = r["dest"]
        if dest in current:
            print(f"  [PRESENT]  {dest}  ->  {r['gateway']}")
        else:
            print(f"  [MISSING]  {dest}  ->  {r['gateway']}")

else:
    print(f"ERROR: unknown action '{action}'", file=sys.stderr)
    sys.exit(1)
PYEOF
  printf '%s' "$tmp"
}

PY_HELPER=""
_ensure_helper() {
  if [[ -z $PY_HELPER ]]; then
    PY_HELPER=$(_write_py_helper)
  fi
}
trap '_cleanup_helper' EXIT
_cleanup_helper() { [[ -n $PY_HELPER ]] && rm -f "$PY_HELPER"; }

py() { python3 "$PY_HELPER" "$@"; }

# ── ensure JSON file / dir exists ────────────────────────────────────────────
_ensure_routes_file() {
  if [[ ! -f $ROUTES_FILE ]]; then
    mkdir -p "$(dirname "$ROUTES_FILE")"
    printf '{"sets":{}}\n' > "$ROUTES_FILE"
    info "Created new routes file: $ROUTES_FILE"
  fi
}

# ── address-family filter ────────────────────────────────────────────────────
_af_flags() {
  if [[ $FILTER_IPV4 -eq 1 ]]; then printf -- '-f inet'; fi
  if [[ $FILTER_IPV6 -eq 1 ]]; then printf -- '-f inet6'; fi
}

# ── actions ──────────────────────────────────────────────────────────────────

do_list() {
  _ensure_helper
  _ensure_routes_file
  info "Route sets in ${ROUTES_FILE}:"
  py list "$ROUTES_FILE"
}

do_show() {
  _ensure_helper
  _ensure_routes_file
  py show "$ROUTES_FILE"
}

do_apply() {
  if [[ ${#ACTION_NAMES[@]} -eq 0 ]]; then
    err "--apply requires at least one set name."
    exit 1
  fi
  require_root
  _ensure_helper
  _ensure_routes_file

  if [[ $RESET_ALL -eq 1 ]]; then
    confirm "Delete ALL current static routes before applying?"
    info "Flushing static routes..."
    # Collect static routes and delete them
    local af_flag
    if [[ $FILTER_IPV6 -eq 1 ]]; then af_flag="-f inet6"; else af_flag="-f inet"; fi
    while IFS= read -r line; do
      local dest
      dest=$(echo "$line" | awk '{print $1}')
      [[ -z $dest ]] && continue
      run_or_echo "route -q delete $dest 2>/dev/null || true"
    done < <(netstat -rn ${af_flag} 2>/dev/null | awk 'NR>3 && $3 ~ /S/ {print $1}')
  fi

  local apply_errors=0
  for name in "${ACTION_NAMES[@]}"; do
    info "Applying set: $name"
    local routes_json
    routes_json=$(py get "$ROUTES_FILE" "$name") || { err "Cannot load set '$name'"; apply_errors=1; continue; }
    # Parse routes with python3 and feed route add commands back
    local apply_py
    apply_py=$(mktemp "${TMPDIR:-/tmp}/apply-routes.XXXXXX")
    cat > "$apply_py" << 'APPLYEOF'
import sys, json
routes = json.loads(sys.stdin.read())
for r in routes:
    dest    = r["dest"]
    gateway = r["gateway"]
    iface   = r.get("interface", "")
    cmd = f"route -q add {dest} {gateway}"
    if iface:
        cmd += f" -interface {iface}"
    print(cmd)
APPLYEOF
    local cmds
    cmds=$(echo "$routes_json" | python3 "$apply_py")
    rm -f "$apply_py"

    while IFS= read -r cmd; do
      [[ -z $cmd ]] && continue
      run_or_echo "$cmd"
    done <<< "$cmds"
    ok "Applied set: $name"
  done
  [[ $apply_errors -eq 0 ]] || exit 1
}

do_save() {
  _ensure_helper
  _ensure_routes_file

  info "Capturing current static routes..."
  local af_flag=""
  if [[ $FILTER_IPV4 -eq 1 ]]; then af_flag="-f inet"; fi
  if [[ $FILTER_IPV6 -eq 1 ]]; then af_flag="-f inet6"; fi

  local tmpfile
  tmpfile=$(mktemp "${TMPDIR:-/tmp}/routes-capture.XXXXXX")

  # Build flat list: dest gateway [interface|-]
  netstat -rn ${af_flag} 2>/dev/null \
    | awk 'NR>3 && $3 ~ /S/ {print $1, $2, $NF}' \
    > "$tmpfile" || true

  local py_save
  py_save=$(mktemp "${TMPDIR:-/tmp}/save-routes.XXXXXX")
  cat > "$py_save" << 'SAVEEOF'
import sys, json, os, tempfile
jfile = sys.argv[1]
name  = sys.argv[2]
lines_file = sys.argv[3]

def load():
    if not os.path.exists(jfile):
        return {"sets": {}}
    with open(jfile) as f:
        return json.load(f)

def save_json(data):
    tmp = jfile + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, jfile)

routes = []
with open(lines_file) as f:
    for line in f:
        parts = line.split()
        if len(parts) < 2:
            continue
        entry = {"dest": parts[0], "gateway": parts[1]}
        if len(parts) >= 3 and parts[2] not in ("-", ""):
            entry["interface"] = parts[2]
        routes.append(entry)

data = load()
data.setdefault("sets", {})[name] = routes
save_json(data)
print(f"Saved {len(routes)} route(s) into set '{name}'")
SAVEEOF

  python3 "$py_save" "$ROUTES_FILE" "$SAVE_NAME" "$tmpfile"
  rm -f "$py_save" "$tmpfile"
  ok "Done. File: $ROUTES_FILE"
}

do_delete() {
  _ensure_helper
  confirm "Delete set '${DELETE_NAME}' from ${ROUTES_FILE}?"
  py delete "$ROUTES_FILE" "$DELETE_NAME"
}

do_rename() {
  _ensure_helper
  py rename "$ROUTES_FILE" "$RENAME_OLD" "$RENAME_NEW"
}

do_diff() {
  _ensure_helper
  _ensure_routes_file
  info "Comparing set '${DIFF_NAME}' against current routing table..."

  local af_flag=""
  if [[ $FILTER_IPV4 -eq 1 ]]; then af_flag="-f inet"; fi
  if [[ $FILTER_IPV6 -eq 1 ]]; then af_flag="-f inet6"; fi

  local current_dests
  current_dests=$(netstat -rn ${af_flag} 2>/dev/null | awk 'NR>3 {print $1}')

  # Pass current destinations as extra args
  py diff "$ROUTES_FILE" "$DIFF_NAME" ${current_dests}
}

# ── dispatch ─────────────────────────────────────────────────────────────────
check_macos_version

case $ACTION in
  list)   do_list ;;
  show)   do_show ;;
  apply)  do_apply ;;
  save)   do_save ;;
  delete) do_delete ;;
  rename) do_rename ;;
  diff)   do_diff ;;
  *)      err "Unknown action: $ACTION"; exit 1 ;;
esac

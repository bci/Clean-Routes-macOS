# Prompt — macOS Conditional DNS Management

## Context

This prompt extends the **macos-routes** script suite
(`Clean-Routes-macOS/`) to add first-class conditional DNS management.

Conditional DNS on macOS works by writing domain-specific resolver configuration
files to `/etc/resolver/<domain>`. Each file tells the system which nameserver(s)
to use for that domain, leaving all other domains to the global DNS setting. This
is essential for split-DNS VPN environments (site-to-site, Meraki MX, etc.) and
local development domain isolation.

The existing `Conditional_DNS_macOS` scripts (`Add-Conditional-DNS.sh`,
`Locasta-Conditional-DNS.sh`) do this well but are **hard-coded config files** —
one script per site. The goal here is to absorb that pattern into the shared
script suite as a general-purpose `dns-macos-routes.sh` tool backed by the same
JSON config format already used by `add-macos-routes.sh`, and to wire conditional
DNS awareness into the existing diagnostic, watch, backup, and reset scripts.

The user will review this prompt before any code is generated.
**Do not generate code until explicitly asked.**

---

## Source Material — Existing Conditional DNS Scripts

The scripts in `Conditional_DNS_macOS/` establish the behavioural contract that
the new implementation must honour. Key observations:

### `/etc/resolver/<domain>` file format

```text

nameserver 172.17.2.3
nameserver 172.17.2.25
domain ci.gardena.ca.us

```

One line per nameserver, then `domain <domain>`. macOS's mDNSResponder reads
this at query time — no reload command needed.

### Configuration model (current, hard-coded)

Each domain entry has five fields:

- `domain` — the DNS suffix, becomes the filename under `/etc/resolver/`
- `nameservers` — one or more resolver IP addresses
- `networks` — zero or more CIDR networks whose traffic should be statically
  routed via `LOCAL_ROUTER_IP` *instead of* the VPN default route
- `test_host` — hostname to probe with `dscacheutil` after applying
- `ping_host` — optional hostname to `ping -c2` for connectivity verification

### Current limitations to fix

1. Config is baked into the script — no file-driven management
2. No `--dry-run`, `--list`, `--remove`, or `--diff` modes
3. No backup/restore for `/etc/resolver/` files
4. Route and DNS configuration are inseparable — can't update one without the other
5. Does not source `lib/common.sh` — duplicate colour/output helpers
6. No integration with the route-watching or diagnostic scripts
7. Uses `eval` for indirect array expansion (fragile, shellcheck warns)
8. CIDR-to-netmask conversion is a pure-bash bitshift — works, but inconsistent
   with the rest of the suite (which uses `python3` for all IP math)

---

## JSON Config Format Extension

The existing `routes.json` format (`{"sets":{...}}`) is extended with a top-level
`"dns"` key. The `"dns"` entries are stored **separately** from route sets —
DNS profiles are not route sets. They may reference the same CIDR networks, but
they are managed independently.

### Extended `routes.json` schema

```json

{
  "sets": {
    "gardena": [
      { "dest": "172.16.0.0/12", "gateway": "192.168.42.1" }
    ]
  },
  "dns": {
    "profiles": {
      "<profile-name>": {
        "domain":      "ci.gardena.ca.us",
        "nameservers": ["172.17.2.3", "172.17.2.25"],
        "networks":    ["172.16.0.0/12"],
        "local_router": "192.168.42.1",
        "test_host":   "mdc.ci.gardena.ca.us",
        "ping_host":   "mdc.ci.gardena.ca.us"
      }
    }
  }
}

```

**Fields:**

| Field | Required | Description |
| ------- | ---------- | ------------- |
| `domain` | ✅ | DNS suffix; written to `/etc/resolver/<domain>` |
| `nameservers` | ✅ | Array of DNS server IPs (one or more) |
| `networks` | ✗ | CIDRs to route via `local_router` (may be empty `[]`) |
| `local_router` | ✗ | Gateway IP for `networks`. Falls back to the profile-level default; then to a global `"dns.local_router"` key; then errors if `networks` is non-empty |
| `test_host` | ✗ | FQDN to probe with `dscacheutil -q host` after applying |
| `ping_host` | ✗ | FQDN to `ping -c2` after applying (skipped if empty or omitted) |

A global `local_router` may also be placed at `dns.local_router` as a top-level
default for all profiles that don't specify their own:

```json

{
  "dns": {
    "local_router": "192.168.42.1",
    "profiles": { ... }
  }
}

```

---

## New Script: `dns-macos-routes.sh`

### Summary

Manage macOS conditional DNS profiles: apply, remove, list, diff, backup, and
restore `/etc/resolver/` files. Optionally also apply/remove the associated
static routes. Sources `lib/common.sh`. Requires `sudo` for write operations.

### Flags

| Flag | Needs root | Description |
| ------ | ----------- | ------------- |
| `--load <path>` | — | JSON file path (default: `~/.config/macos-routes/routes.json`) |
| `--list` | — | Print all DNS profiles from the JSON file and exit |
| `--show` | — | Print current `/etc/resolver/` files and their content |
| `--apply <name> [<name2>…]` | ✅ | Write `/etc/resolver/<domain>` files and optionally add routes |
| `--remove <name> [<name2>…]` | ✅ | Delete `/etc/resolver/<domain>` files and optionally remove routes |
| `--remove-all` | ✅ | Remove **all** `/etc/resolver/` files (not just ones in the JSON) |
| `--with-routes` | — | When combined with `--apply`/`--remove`, also add/remove the `networks` routes via `networksetup -setadditionalroutes` |
| `--local-router <IP>` | — | Override `local_router` for this invocation |
| `--diff <name> [<name2>…]` | — | Compare JSON profile(s) against live `/etc/resolver/` and routing table |
| `--save <name>` | — | Read an existing `/etc/resolver/<domain>` file and current routing table, create/update a JSON profile named `<name>` |
| `--delete <name>` | — | Remove a profile from the JSON file (does not touch `/etc/resolver/`) |
| `--rename <old> <new>` | — | Rename a profile in the JSON file |
| `--backup [<file>]` | — | Snapshot all current `/etc/resolver/` files to a JSON archive |
| `--restore <file>` | ✅ | Restore `/etc/resolver/` files from a JSON archive |
| `--flush-cache` | ✅ | Flush DNS cache (`dscacheutil -flushcache` + `killall -HUP mDNSResponder`) |
| `--test <name> [<name2>…]` | — | Run `dscacheutil` and optional `ping` tests for the named profile(s) |
| `-n, --dry-run` | — | Print commands without executing |
| `-v, --verbose` | — | Print each command before executing |
| `-y, --yes` | — | Skip confirmation prompts |
| `-h, --help` | — | Show usage and exit |

### Behaviour Details

#### `--list`

Tabular output, no root needed:

```text

Profile           Domain                   Nameservers          Networks
gardena           ci.gardena.ca.us         172.17.2.3           172.16.0.0/12
                                           172.17.2.25
mde               mde.local                10.0.0.9             10.0.0.0/24

```

#### `--show`

Reads all files currently present in `/etc/resolver/` and prints their content
with a header per file. Also prints a note if any file is not tracked in the
JSON (i.e., was created by another tool):

```text

/etc/resolver/ci.gardena.ca.us  [tracked: gardena]
  nameserver 172.17.2.3
  nameserver 172.17.2.25
  domain ci.gardena.ca.us

/etc/resolver/some.unknown.domain  [UNTRACKED]
  nameserver 8.8.8.8

```

#### `--apply <name> [<name2>…]`

1. Validate profile exists in JSON; error if not found.
2. Write `/etc/resolver/<domain>`:

   ```text

   nameserver <ip1>
   nameserver <ip2>
   domain <domain>
   ```

   Write atomically: write to `/etc/resolver/<domain>.tmp`, then `mv`.
3. If `--with-routes` and `networks` is non-empty:
   - Determine `local_router` (profile → global → flag → error).
   - Use `python3` to convert each CIDR to `network_addr netmask` (consistent
     with rest of suite; no bash bitshift).
   - Call `networksetup -setadditionalroutes <service> <dest> <mask> <gw> …`,
     **preserving existing routes** (read first, merge, dedup, write back).
   - Service selection: use `networksetup -listallnetworkservices`, prefer the
     first active Ethernet or Wi-Fi service; allow override via `--service <svc>`.
4. Optionally run `--test` for each applied profile (if `test_host` is set).
5. Flush DNS cache after writing resolver files.

#### `--remove <name> [<name2>…]`

1. Validate profile exists in JSON; warn (not error) if `/etc/resolver/<domain>`
   is already absent.
2. Delete `/etc/resolver/<domain>`.
3. If `--with-routes` and `networks` is non-empty:
   - Read current `networksetup -getadditionalroutes` for the service.
   - Remove entries matching the profile's CIDRs (using python3 CIDR overlap).
   - Write back remaining routes.
4. Flush DNS cache.

#### `--remove-all`

- Prompt unless `--yes`.
- Delete all files under `/etc/resolver/`.
- Does **not** touch routes (to remove routes, combine with `clean-macos-routes.sh`).
- Flush DNS cache.

#### `--diff <name>`

Read-only. Compares the JSON profile definition against live state:

```text

Profile: gardena  (domain: ci.gardena.ca.us)

Resolver file (/etc/resolver/ci.gardena.ca.us):
  nameserver 172.17.2.3    [PRESENT]
  nameserver 172.17.2.25   [PRESENT]

Routes (via networksetup):
  172.16.0.0/12  ->  192.168.42.1   [PRESENT]

DNS test (test_host: mdc.ci.gardena.ca.us):
  [RESOLVED]  172.17.2.5

Ping test (ping_host: mdc.ci.gardena.ca.us):
  [REACHABLE]

```

If the resolver file is missing: `[MISSING]`.
If a route is absent from `networksetup -getadditionalroutes`: `[MISSING]`.
If a route is present but not in the profile: `[EXTRA]`.

#### `--save <name>`

Introspect live state and create/update a JSON profile:

1. Read `/etc/resolver/<domain>` (ask user to supply `--domain <domain>` if
   the profile doesn't already exist in the JSON — domain can't be inferred).
2. Parse nameserver lines.
3. Read current `networksetup -getadditionalroutes` for all services; let user
   optionally confirm which networks belong to this profile (or accept all with `--yes`).
4. Write to JSON atomically.

#### `--backup [<file>]`

No root needed. Creates a JSON archive:

```json

{
  "created": "ISO8601",
  "hostname": "...",
  "macos_version": "...",
  "resolver_files": {
    "ci.gardena.ca.us": "nameserver 172.17.2.3\nnameserver 172.17.2.25\ndomain ci.gardena.ca.us\n",
    "mde.local": "nameserver 10.0.0.9\ndomain mde.local\n"
  }
}

```

Default path: `~/.config/macos-routes/backups/<timestamp>-dns.json`.

#### `--restore <file>`

Requires root. Reads the backup archive, writes each `resolver_files` entry
atomically to `/etc/resolver/<domain>`. Prompts unless `--yes`.

#### `--test <name> [<name2>…]`

Runs post-apply verification for one or more profiles. No root needed.
For each profile:

1. `dscacheutil -q host -a name <test_host>` — report resolved IPs or `[FAILED]`.
2. `ping -c2 -W2 <ping_host>` (if set) — report `[REACHABLE]` or `[UNREACHABLE]`.

#### `--flush-cache`

```bash

dscacheutil -flushcache
killall -HUP mDNSResponder

```

Called automatically after `--apply` and `--remove`. Also available standalone.

### CIDR-to-netmask conversion

Do **not** use the bash bitshift method from the existing scripts. Use `python3`:

```python

import ipaddress, sys
net = ipaddress.ip_network(sys.argv[1], strict=False)
print(net.network_address, net.netmask)

```

This is consistent with how all other IP math works in the suite.

### Temp file and cleanup rules

- All python3 helpers written via `mktemp` (`.py` suffix), cleaned up in `trap … RETURN` or `trap … EXIT`.
- Atomic resolver file writes: write to `<path>.tmp`, then `mv`.

- No heredoc Python under sudo.

---

## Changes to Existing Scripts

### `lib/common.sh`

**Add** the following helpers (no changes to existing functions):

```bash

# -- DNS helpers --------------------------------------------------------------

# Flush macOS DNS cache
flush_dns_cache() {
  run_or_echo "dscacheutil -flushcache 2>/dev/null || true"
  run_or_echo "killall -HUP mDNSResponder 2>/dev/null || true"
}

# Write a single /etc/resolver/<domain> file atomically
# Usage: write_resolver_file <domain> <nameserver1> [<nameserver2> ...]
write_resolver_file() {
  local domain="$1"; shift
  local resolver_file="/etc/resolver/${domain}"
  local tmp="${resolver_file}.tmp"
  mkdir -p /etc/resolver
  {
    for ns in "$@"; do
      printf "nameserver %s\n" "$ns"
    done
    printf "domain %s\n" "$domain"
  } > "$tmp"
  mv "$tmp" "$resolver_file"
}

# Remove a /etc/resolver/<domain> file
remove_resolver_file() {
  local domain="$1"
  local resolver_file="/etc/resolver/${domain}"
  if [[ -f "$resolver_file" ]]; then
    run_or_echo "rm -f \"$resolver_file\""
  fi
}

# List all /etc/resolver/ files
list_resolver_files() {
  ls /etc/resolver/ 2>/dev/null || true
}

# cidr_to_dest_mask <CIDR> → prints "network_addr netmask" (python3)
# Example: cidr_to_dest_mask 172.16.0.0/12 → 172.16.0.0 255.240.0.0
cidr_to_dest_mask() {
  python3 -c "
import ipaddress, sys
net = ipaddress.ip_network(sys.argv[1], strict=False)
print(net.network_address, net.netmask)
" "$1"
}

```

**Constants to add** (alongside existing `ROUTES_*`):

```bash

DNS_BACKUP_DIR="${ROUTES_CONFIG_DIR}/backups"   # already set as ROUTES_BACKUP_DIR — reuse
RESOLVER_DIR="/etc/resolver"

```

---

### `diagnose-macos-routes.sh`

**Add a new section** — "Conditional DNS" — between the ARP table and the
networksetup additional routes sections:

```text

── Conditional DNS (/etc/resolver/) ───────────────────
  ci.gardena.ca.us
    nameserver 172.17.2.3
    nameserver 172.17.2.25
    domain ci.gardena.ca.us
  mde.local
    nameserver 10.0.0.9
    domain mde.local
  (none configured)

```

**Add to `--json` output**: a `"conditional_dns"` key whose value is an object
mapping each filename to its raw text content:

```json

"conditional_dns": {
  "ci.gardena.ca.us": "nameserver 172.17.2.3\n...",
  "mde.local": "nameserver 10.0.0.9\n..."
}

```

Implementation: read each file under `/etc/resolver/` (no root needed — files
are world-readable on macOS).

---

### `watch-macos-routes.sh`

**Add a `--watch-dns` flag**: in addition to polling the routing table, also
poll `/etc/resolver/` for additions and removals.

```text

2026-04-14T10:05:00Z  [DNS ADDED]   /etc/resolver/ci.gardena.ca.us
2026-04-14T10:06:30Z  [DNS REMOVED] /etc/resolver/mde.local

```

Implementation:

- Maintain a `prev_dns_snapshot` temp file (sorted list of filenames in
  `/etc/resolver/`).
- On each poll interval, `comm -13`/`-23` against current list → print `[DNS ADDED]`
  / `[DNS REMOVED]` with ISO timestamp.
- Summary at exit: add `dns_added_count` / `dns_removed_count` to the existing
  `ADDED_COUNT`/`REMOVED_COUNT` summary block.

**Add a `--restore-dns <name>`** flag: when a tracked resolver file disappears,
auto-reapply it from the JSON profile (calls `write_resolver_file` from
`lib/common.sh`). Requires root if auto-restore fires.

---

### `backup-restore-routes.sh`

**Add `--include-dns` flag** to `--backup`:

- In addition to the existing netstat + networksetup additional routes, also
  capture all files in `/etc/resolver/` into a `"resolver_files"` key in the
  JSON backup (same format as `dns-macos-routes.sh --backup`).

**Add `--include-dns` flag** to `--restore`:

- When the backup JSON contains a `"resolver_files"` key, write each file
  back to `/etc/resolver/` atomically. Requires root.

**Add `--list-dns` sub-flag** to `--diff`:

- Include a "Conditional DNS" section in the diff output comparing the backup's
  `resolver_files` against the live `/etc/resolver/` contents.

---

### `reset-macos-network.sh`

**Add `--flush-dns-resolvers` flag**:

- Delete all files under `/etc/resolver/` (prompts unless `--yes`).
- Follows with `flush_dns_cache` (already in the script's DNS flush step).
- Clearly distinct from flushing the DNS *cache* — this removes *conditional
  resolver configuration*.

The existing `--flush-static` (static routes only) is the route analogue.
This new flag is the DNS analogue.

Do **not** make the main reset path automatically flush `/etc/resolver/` —
only when explicitly requested, since wiping conditional DNS is usually *not*
what a general reset needs to do.

---

### `clean-macos-routes.sh`

No changes required. The route-only nature of this script is intentional.
DNS management belongs in `dns-macos-routes.sh`.

---

### `add-macos-routes.sh`

No changes required. Route sets and DNS profiles are separate top-level keys
in the JSON file and managed by separate tools.

---

## Style Rules (same as `prompt-macos-routes.md`)

- `set -euo pipefail` in every script
- `source "${SCRIPT_DIR}/lib/common.sh"` — all colour/output helpers from there
- `DRY_RUN`, `VERBOSE`, `ASSUME_YES` globals; every destructive call via `run_or_echo`
- Python helpers: always `mktemp` + explicit args, **never** inline heredoc under sudo

- Heredoc terminators at **column 0**
- Atomic file writes: write to `<path>.tmp`, then `mv`

- Temp files cleaned via `trap … RETURN` or `trap … EXIT`
- Interactive prompts default to **No**
- macOS-only tools only; no `brew` dependencies

---

## Migration Path from Existing Scripts

The two existing scripts (`Add-Conditional-DNS.sh`, `Locasta-Conditional-DNS.sh`)
can be retired once `dns-macos-routes.sh` is in place. The migration path is:

1. **Import** existing site config into the JSON file:

   ```bash

   # For Locasta site (gardena + mde.local)
   # Manually add to routes.json under "dns" > "profiles" — or use --save after
   # running the old script once to populate /etc/resolver/ from known state.
   dns-macos-routes.sh --save gardena --domain ci.gardena.ca.us
   dns-macos-routes.sh --save mde --domain mde.local
   ```

2. **Verify** with `--diff gardena mde`.
3. **Replace** old scripts: `dns-macos-routes.sh --apply gardena mde --with-routes`.
4. **Archive** the old scripts (don't delete — they're in a separate repo).

---

## Summary of Files to Create / Modify

| File | Action | What changes |
| ------ | -------- | ------------- |
| `dns-macos-routes.sh` | **Create** | New script; all DNS profile management |
| `lib/common.sh` | **Modify** | Add `flush_dns_cache`, `write_resolver_file`, `remove_resolver_file`, `list_resolver_files`, `cidr_to_dest_mask` helpers; add `RESOLVER_DIR` constant |
| `diagnose-macos-routes.sh` | **Modify** | Add conditional DNS section to human + JSON output |
| `watch-macos-routes.sh` | **Modify** | Add `--watch-dns` and `--restore-dns` flags |
| `backup-restore-routes.sh` | **Modify** | Add `--include-dns` to `--backup`/`--restore`; `--list-dns` to `--diff` |
| `reset-macos-network.sh` | **Modify** | Add `--flush-dns-resolvers` flag |
| `clean-macos-routes.sh` | **No change** | Route-only; DNS is out of scope |
| `add-macos-routes.sh` | **No change** | Route sets only; DNS profiles are separate |

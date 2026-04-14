# Prompt — macOS Route Management Scripts

## Context

You are generating a set of three bash scripts for macOS network route management.
All scripts must target **macOS (Darwin)** and use only tools available by default:
`route`, `netstat`, `networksetup`, `ifconfig`, `ipconfig`, `arp`,
`dscacheutil`, `launchctl`, `mDNSResponder`, `python3`, `awk`, `sed`, `grep`.

The scripts live in the same directory and share a common coding style (see §Style).
The user will review this prompt before any code is generated. Do not generate code
until explicitly asked.

---

## Existing Scripts

These scripts may be modified, refactored, or fully replaced as needed. There are
no constraints on approach — improve structure, fix bugs, rename flags, change
behaviour, or rewrite from scratch if that produces a better result. The
descriptions below document current behaviour as a reference baseline only.

### `reset-macos-network.sh`

Full network-stack reset. Requires `sudo`. Key operations:

- **Flag parsing** — `set -euo pipefail`; flags: `-v/--verbose`, `-n/--dry-run`,
  `-f/--force`, `-y/--yes`, `--keep-default`, `--default-gateway <IP>`,
  `--default-if <iface>`, `-l/--list-routes [ipv4|ipv6]`, `--ipv4`, `--ipv6`,
  `-F/--filter-dest <pattern>`, `-p/--persistence`, `-h/--help`.
- **`print_routes_and_exit()`** — called first; if `-l`/`--ipv4`/`--ipv6` is set,
  print the routing table (optionally filtered by `-F`, optionally annotated with
  `[PERSISTENT: <files>]` or `[EPHEMERAL]` via `-p`), then `exit 0`.
  Uses a temp Python script for CIDR-aware destination filtering.
- **SSH guard** — aborts when `$SSH_CONNECTION` is set unless `--force`.
- **Interactive confirm** — prompts before destructive changes; skipped by `-y`/`-n`.
- **Route flush** — `route -n flush`; falls back to per-route `route delete`.
- **Default gateway preserve/restore** — captures gateways before flush;
  re-adds them if `--keep-default` or `--default-gateway` is given.
- **ARP flush** — `arp -a` piped through awk to extract IPs; `arp -d` per entry.
- **DNS flush** — `dscacheutil -flushcache`, `killall -HUP mDNSResponder`.
- **DHCP reset** — iterates `networksetup -listallnetworkservices`;
  calls `networksetup -setdhcp` per service (service-name first, device fallback).
- **Interface cycling** — `ifconfig -a` parsed for non-loopback interfaces;
  `ifconfig <if> down/up`, `ipconfig set <if> DHCP`.
- **Daemon restart** — `launchctl kickstart` for mDNSResponder and network prefs.
- **Startup scan** — `grep -RIn` across common plist/config dirs for
  `route`/`ipconfig` references; warns if found.

### `clean-macos-routes.sh`

Targeted removal of **static IPv4 routes** (flag `S` in `netstat`). Does **not**
require sudo to list; `sudo` is invoked inline for `route delete` and
`networksetup -setadditionalroutes`. Key operations:

- **Flag parsing** — `--dry-run`, `--yes`, `--filter <pattern>` (grep-style on
  the raw `netstat` line), `--network <CIDR>` (python3 CIDR overlap check),
  `--persist` (also update `networksetup -setadditionalroutes`),
  `--uninstall-persist` (restore most-recent backup from
  `/var/tmp/clean_static_routes_backups/<ts>/`).
- **Route discovery** — `netstat -rn -f inet`, skip first 3 header lines,
  keep only lines where column 3 contains `S`.
- **Filtering** — optional grep-style `--filter`; optional python3 CIDR overlap
  for `--network`.
- **Interactive deletion** — per-route prompt `[y/N/q]`; skipped with `--yes`.
- **Persistence** — backs up current `networksetup -getadditionalroutes` output
  per service to timestamped dir; then calls
  `networksetup -setadditionalroutes <svc> [remaining...]` to strip matched routes.
- **Restore** — `--uninstall-persist` reads the latest backup dir and re-applies
  saved routes via `networksetup -setadditionalroutes`.

---

## New Scripts

### Purpose

Apply one or more pre-configured named route sets to the macOS routing table,
managing a JSON "route definition file" as the authoritative source of named sets.
Optionally wipe all existing routes before applying. Does **not** touch DNS,
ARP, or interface state — route additions only.

### JSON Route Definition File Format

```json
{
  "sets": {
    "<name>": [
      { "dest": "172.16.0.0/12", "gateway": "192.168.1.1", "interface": "en0" },
      { "dest": "10.8.0.0/16",   "gateway": "10.0.0.1" }
    ]
  }
}
```

- `"sets"` — top-level object; keys are arbitrary set names (e.g. `"home"`,
  `"traveling"`, `"cogvpn"`).
- Each entry requires `"dest"` (CIDR or host) and `"gateway"`.
  `"interface"` is optional; when present, passed as `-ifscope <iface>` to `route add`.
- The file path is specified at runtime via `--load`; a default path can be
  baked into the script as a constant (e.g. `~/.config/macos-routes/routes.json`).

### Flags

| Flag | Description |
| --- | --- |
| `--load <path>` | Path to the JSON route definition file. Overrides the compiled-in default. |
| `--list` | Print all named sets and their routes from the loaded JSON file, then exit. Does not require `sudo`. |
| `--apply <name> [<name2> …]` | Apply the named set(s) from the loaded JSON file. Each route is added with `sudo route add`. Multiple names may be given. |
| `--reset-all` | Remove **all** current non-loopback IPv4 static routes before applying (equivalent to `route -n flush` or per-route delete fallback). When combined with `--apply`, the flush happens first. |
| `--save <name>` | Capture the **current** routing table static routes (flag `S` in `netstat`) and save them as set `<name>` in the loaded JSON file, overwriting any existing set with that name. |
| `--show` | Print the live macOS routing table (`netstat -rn`) and exit. Does not require `sudo`. Supports `--ipv4` / `--ipv6` sub-filters (same as `reset-macos-network.sh`). |
| `--ipv4` | Restrict `--show` output to IPv4. |
| `--ipv6` | Restrict `--show` output to IPv6. |
| `-n, --dry-run` | Print all `route add` / `route delete` commands without executing them. |
| `-v, --verbose` | Echo each command before execution. |
| `-y, --yes` | Skip interactive confirmation for `--reset-all`. |
| `-h, --help` | Print usage and exit. |

### Behaviour Details

1. **`--load`** — parse the JSON file using `python3 -c` (no external deps).
   Fail with a clear error if the file is missing or malformed.
   If no `--load` is given, use the compiled-in default path; if that also
   doesn't exist, start with an empty `{"sets":{}}` structure in memory.

2. **`--list`** — formatted table output per set, e.g.:

   ```text
   Set: home (3 routes)
     172.16.0.0/12   via 192.168.1.1   (en0)
     10.8.0.0/16     via 10.0.0.1
   Set: cogvpn (1 route)
     10.100.0.0/16   via 172.16.5.1
   ```


3. **`--apply <name>`** — requires `sudo` (check `$EUID`; error if not root).
   For each route entry call:

   ```bash
   route add -net <dest> <gateway> [-ifscope <interface>]
   ```

   Report success/failure per route. Continue on individual failures (log warning).
   When `--dry-run`, print the would-be commands instead.

4. **`--reset-all`** — attempt `route -n flush`; on failure iterate
   `netstat -rn -f inet` and `route delete` each non-loopback non-default entry.
   Prompt the user unless `--yes` or `--dry-run`.

5. **`--save <name>`** — parse current `netstat -rn -f inet` (flag `S` lines only,
   same logic as `clean-macos-routes.sh`). For each route extract `dest`, `gateway`,
   and `Netif` (interface). Write back to the JSON file atomically (write to
   `<file>.tmp` then `mv`). Does **not** require `sudo`.

6. **`--show`** — thin wrapper around `netstat -rn [-f inet | -f inet6]`.
   No persistence annotation (that's `reset-macos-network.sh`'s domain).

7. **Combination rules**
   - `--reset-all` runs before `--apply` when both are given.
   - `--save` and `--apply` may not be combined (conflict — exit with error).
   - `--list` and `--show` always exit after printing.

---

## `diagnose-macos-routes.sh`

### What it does

Read-only diagnostic tool. Produces a single formatted report covering routing
state, ARP, DNS, VPN interfaces, and gateway reachability. No `sudo` required;
all information is gathered from read-only commands.

### `diagnose` Flags

| Flag | Description |
| --- | --- |
| `--ipv4` | Restrict routing table output to IPv4. |
| `--ipv6` | Restrict routing table output to IPv6. |
| `--json` | Output the full report as JSON instead of human-readable text. |
| `--check-gateway` | Ping the default gateway(s) and report reachability (adds a short delay). |
| `-v, --verbose` | Include additional detail (full ARP table, all interfaces). |
| `-h, --help` | Print usage and exit. |

### Report Sections (human-readable mode)

1. **System** — hostname, macOS version, uptime.
2. **Routing table** — `netstat -rn` output (filtered by `--ipv4`/`--ipv6` if given).
3. **Default gateway(s)** — extracted from routing table; optional ping check with `--check-gateway`.
4. **DNS servers** — parsed from `scutil --dns` (primary resolver only unless `--verbose`).
5. **Active VPN interfaces** — detect `utun*`, `ppp*`, `ipsec*` interfaces via `ifconfig -a`; show IP and status.
6. **ARP cache summary** — count of entries; full table with `--verbose`.
7. **Static routes** — routes with flag `S` from `netstat`; highlight any that overlap RFC-1918 ranges.
8. **networksetup additional routes** — iterate `networksetup -listallnetworkservices`; show per-service additional routes if any exist.

### JSON output (`--json`)

A single JSON object with keys matching the section names above, values being
arrays of structured records. Use `python3` to build and print the JSON.

---

## `watch-macos-routes.sh`

### What `watch` does

Continuously monitor the macOS routing table for changes and log additions and
removals with timestamps. Optionally re-apply a named route set from an
`add-macos-routes.sh` JSON file when a watched route disappears.

### `watch` Flags

| Flag | Description |
| --- | --- |
| `--interval <seconds>` | Poll interval in seconds. Default: `5`. |
| `--ipv4` | Watch IPv4 routes only. |
| `--ipv6` | Watch IPv6 routes only. |
| `--filter <pattern>` | Only report changes to routes whose destination matches the pattern (prefix or CIDR). |
| `--log <file>` | Append change events to a file in addition to stdout. |
| `--restore-set <name>` | When a route from the named set (loaded via `--load`) disappears, automatically re-apply it with `sudo route add`. |
| `--load <path>` | Path to the JSON route definition file (used with `--restore-set`). |
| `--once` | Print the current routing table, then exit (no polling). Equivalent to `--show` in `add-macos-routes.sh`. |
| `-v, --verbose` | Print the full routing table snapshot on each poll cycle. |
| `-h, --help` | Print usage and exit. |

### `watch` Behaviour Details

- On startup, take an initial snapshot of the routing table.
- Each poll: diff the current table against the previous snapshot.
  - Print `[ADDED]` / `[REMOVED]` lines with a timestamp prefix.
  - Append to `--log` file if specified.
- With `--restore-set`: after detecting a removal, check whether the removed
  destination belongs to the named set; if so, run `sudo route add …` to restore
  it. Warn if not running as root and `--restore-set` is given.
- Use `trap` on `INT`/`TERM` to print a summary (total changes seen) and exit cleanly.
- Change event log format:

  ```text
  2026-04-14T10:23:01 [REMOVED] 172.16.0.0/12  via 192.168.1.1  en0
  2026-04-14T10:23:06 [ADDED]   10.8.0.0/16    via 10.0.0.1
  ```

---

## `backup-restore-routes.sh`

### What `backup-restore` does

Full routing state snapshot and restore. Captures the live routing table **and**
per-service `networksetup -getadditionalroutes` state into a single JSON file.
Restores on demand. Complements `add-macos-routes.sh --save` (which captures
only static routes) by recording the complete live state.

### `backup-restore` Flags

| Flag | Description |
| --- | --- |
| `--backup [<file>]` | Write current routing state to `<file>`. If omitted, write to `~/.config/macos-routes/backups/<timestamp>.json`. |
| `--restore <file>` | Re-apply routing state from a backup file. Prompts before making changes. |
| `--list-backups` | List available backups in the default backup directory with timestamps and route counts. |
| `--diff <file>` | Compare a backup file against the live routing table; show what would be added or removed. Does not require `sudo`. |
| `--prune [N]` | Delete all but the N most recent backups from the default directory. Default N: `10`. |
| `-n, --dry-run` | Print all `route add` / `networksetup` commands without executing them. |
| `-y, --yes` | Skip interactive confirmation for `--restore`. |
| `-v, --verbose` | Echo each command before execution. |
| `-h, --help` | Print usage and exit. |

### Backup JSON Format

```json
{
  "created": "2026-04-14T10:23:01",
  "hostname": "COVANDOnew",
  "macos_version": "15.4",
  "routes": [
    { "dest": "172.16.0.0/12", "gateway": "192.168.1.1", "flags": "UGSc", "interface": "en0" }
  ],
  "additional_routes": {
    "Wi-Fi": [
      { "dest": "10.8.0.0", "mask": "255.255.0.0", "gateway": "10.0.0.1" }
    ]
  }
}
```

### `backup-restore` Behaviour Details

- **`--backup`** — gather routes from `netstat -rn -f inet` (all flags, not just `S`);
  gather additional routes from `networksetup -getadditionalroutes` per service.
  Write atomically (`<file>.tmp` → `mv`). Does **not** require `sudo`.
- **`--restore`** — read the JSON file; for each route call `sudo route add`;
  for each service with additional routes call
  `sudo networksetup -setadditionalroutes <svc> …`.
  Prompt before starting unless `--yes`. Continue on per-route failure (warn).
- **`--diff`** — compare backup routes against live `netstat` output;
  print `[MISSING]` / `[PRESENT]` / `[EXTRA]` per route. Uses python3 for CIDR
  normalisation.
- **`--prune N`** — sort backup files by name (ISO timestamp prefix ensures
  correct order); delete oldest, keeping N.

---

## Style Guide (apply to all scripts)

- Shebang: `#!/usr/bin/env bash`
- Strict mode: `set -euo pipefail`
- Coloured status helpers already defined in the existing scripts:

  ```bash
  info() { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
  warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
  err()  { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*"; }
  ```

- `run_or_echo` wrapper for dry-run / verbose (see `reset-macos-network.sh`).
- All `route`, `arp`, `networksetup` calls that modify state go through
  `run_or_echo` or an equivalent dry-run guard.
- Python3 helpers are written to a temp file via `mktemp`; never use inline
  heredoc where the script body runs under sudo (avoids stdin/heredoc conflicts).
  Always `rm -f` the temp file in a `trap … RETURN` or after use.
- Heredoc terminators must be **unindented** (column 0) unless the heredoc
  opening uses `<<-` (tab-strip mode).
- Interactive prompts default to **No** (`[y/N]`); destructive ops require
  explicit opt-in.
- `--dry-run` must suppress **every** state-changing call, including
  `networksetup`, `arp -d`, `ifconfig`, `launchctl`.
- Temp files: always `mktemp`; always cleaned up via `trap … RETURN` or `trap … EXIT`.

---

## Suggested Improvements & Future Ideas

These are open suggestions — implement any or all, propose better alternatives,
or ignore them if they don't fit the design. Nothing here is mandatory.

### Cross-script / general

- **Shared library** — extract common helpers (`run_or_echo`, `info`/`warn`/`err`,
  Python CIDR filter, `require_root`, `confirm`) into a single sourced file
  (e.g. `lib/common.sh`) to eliminate duplication across the three scripts.
- **Unified entry point** — a single `macos-routes` dispatcher script with
  sub-commands (`reset`, `clean`, `add`, `show`) rather than three separate files.
  Easier to install (one symlink/alias) and keeps a consistent UX.
- **`--log <file>`** — append a timestamped record of every executed command and
  its outcome to a log file. Useful for audit trails on managed machines.
- **Colour output toggle** — respect `NO_COLOR` env var and auto-disable colour
  when stdout is not a TTY.
- **macOS version guard** — warn or abort on unsupported macOS versions where
  `route`/`networksetup` behaviour differs (e.g. pre-Ventura vs Sonoma+).

### Improvements to `reset-macos-network.sh`

- **Fix the heredoc / Python filter bug** — the inline Python CIDR filter has a
  recurring heredoc terminator indentation issue that causes `unexpected end of file`.
  Replace with a proper temp-file approach (`mktemp` + `cat >`) throughout.
- **`-l` / `--list-routes` persistence annotation** — the current grep-based
  heuristic produces false positives (matching unrelated files). Restrict the search
  to lines that contain route-creation commands (`route add`, `networksetup -setmanual`,
  `networksetup -setadditionalroutes`, `ipconfig set`) rather than any occurrence of
  the IP string.
- **`--backup`** — snapshot the current routing table to a timestamped file before
  flushing, so the state can be reviewed or restored manually.
- **`--restore <file>`** — re-apply routes from a snapshot file created by `--backup`.
- **Selective flush** — `--flush-static` to remove only static (`S`-flag) routes
  rather than the entire table; safer on production machines.
- **Parallel interface cycling** — bring interfaces down/up concurrently to reduce
  reset time on machines with many interfaces.

### Improvements to `clean-macos-routes.sh`

- **IPv6 support** — currently IPv4-only; add `--ipv6` / `--all` to also remove
  static IPv6 routes (`netstat -rn -f inet6`).
- **`--network` multi-value** — allow multiple `--network` flags to match routes
  in any of several CIDRs in one pass.
- **Backup rotation** — the timestamped backup dirs in `/var/tmp` accumulate
  indefinitely; add a `--prune-backups [N]` option to keep only the N most recent.
- **`--restore <ts>`** — restore a specific backup by timestamp rather than always
  using the most recent one.
- **Dry-run for `--persist`** — currently the persistence update path does not
  fully respect `--dry-run`; audit and fix all `networksetup` call sites.

### Improvements to `add-macos-routes.sh` (new)

- **`--delete <name>`** — remove a named set from the JSON file.
- **`--rename <old> <new>`** — rename a set in the JSON file.
- **`--diff <name>`** — compare the named set in the JSON file against the live
  routing table and show what would be added or is already present.
- **`--watch`** — poll the routing table every N seconds and re-apply a named set
  if any of its routes disappear (useful after VPN disconnects or DHCP renewals).
- **`--export`** — print the full JSON file contents to stdout (useful for piping
  to `jq` or saving a copy).
- **Route validation** — before calling `route add`, validate that the gateway IP
  is reachable on the specified interface (via `ping -c1 -W1 -b <iface>`); warn
  if not but continue.
- **Multiple JSON files** — allow `--load` to accept a directory; merge all
  `*.json` files found in it into a single set namespace.
- **Shell completion** — generate a `_add-macos-routes` zsh/bash completion script
  that tab-completes set names from the loaded JSON file.

### Additional scripts (ideas)

- **`diagnose-macos-routes.sh`** — read-only diagnostic: show routing table,
  ARP cache, DNS servers, active VPN interfaces, and default gateway reachability
  in a single formatted report. No `sudo` required.
- **`watch-macos-routes.sh`** — continuously monitor the routing table for changes
  (poll `netstat` or use `route monitor`) and log additions/removals with timestamps.
- **`backup-restore-routes.sh`** — dedicated snapshot/restore tool: save the full
  routing table + `networksetup -getadditionalroutes` state to a JSON file, and
  restore it on demand. Complements `add-macos-routes.sh --save` but captures the
  complete live state rather than only static routes.

---

## Generation Instructions (for when the user asks to generate code)

1. You are free to change anything — rewrite, refactor, rename, restructure, or
   replace any of the three scripts in any way that produces a better result.
2. Generate `add-macos-routes.sh` first as it is a new file; then address any
   requested changes to the existing scripts.
3. After generating or modifying any script, run `bash -n <script>` to
   syntax-check it. Fix any errors before presenting.
4. Proactively suggest improvements even if not explicitly requested.

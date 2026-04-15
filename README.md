# macOS Route & DNS Management Suite

[![CI](https://github.com/bci/Clean-Routes-macOS/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/bci/Clean-Routes-macOS/actions/workflows/test.yml)

A collection of bash scripts for managing macOS network routes and conditional
DNS resolvers on macOS. Designed for split-DNS VPN environments — site-to-site
Meraki MX setups, client VPNs, and local-development domain isolation — where
you need fine-grained control over which DNS servers answer for which domains
and which traffic bypasses VPN tunnels via local routing.

All scripts are **macOS-only**, require no Homebrew dependencies, and use only
tools that ship with macOS (bash, python3, networksetup, netstat, route,
dscacheutil, scutil).

---

## Contents

| Script | Root? | Purpose |
| ------ | ----- | ------- |
| `dns-macos-routes.sh` | write ops | Manage `/etc/resolver/` profiles from a JSON config |
| `add-macos-routes.sh` | ✅ | Add, list, diff, and delete named route sets |
| `clean-macos-routes.sh` | ✅ | Remove static routes by network pattern or set |
| `diagnose-macos-routes.sh` | — | Read-only diagnostics (routing table, DNS, VPN, ARP) |
| `report-macos-routes.sh` | — | Snapshot report: conditional DNS, per-service routes, kernel table, VPN tunnels |
| `watch-macos-routes.sh` | — | Poll routing table and `/etc/resolver/` for changes |
| `backup-restore-routes.sh` | restore: ✅ | JSON snapshot, restore, diff, and prune for routes |
| `reset-macos-network.sh` | ✅ | Flush routes, caches, cycle interfaces, reset to DHCP |
| `lib/common.sh` | — | Shared helpers (sourced by all scripts; not executed directly) |

**`local/`** — Site-specific shortcut scripts live here (excluded from git via
`.gitignore`). See [Local Shortcut Scripts](#local-shortcut-scripts) below.

---

## Requirements

- macOS Ventura (13) or later (tested; may work on Monterey)
- zsh 5.8+ (ships with macOS 11+; all scripts use `#!/usr/bin/env zsh`)
- python3 (ships with Xcode Command Line Tools; install with `xcode-select --install`)
- sudo for any operation that writes routes or `/etc/resolver/`

### Optional (development / testing)

- `timeout` (GNU coreutils) — when present, `make test` limits each test file to
  60 s so a hung test can't block CI or your terminal indefinitely.
  Not required to run the scripts themselves.

  ```bash
  brew install coreutils   # provides gtimeout (and timeout) on macOS
  ```

---

## Installation

```bash
git clone https://github.com/<your-org>/macos-routes.git
cd macos-routes
chmod +x *.sh
make setup   # initialises bats submodules + installs pre-push hook
```

`make setup` only needs to be run once after cloning. After that, `git push`
will automatically run `make all` (lint + tests) and block the push if either
fails. To skip in an emergency: `git push --no-verify`.

No package manager, no virtualenv, no build step.

---

## JSON Configuration File

All scripts that manage named sets or DNS profiles read from a shared JSON file.

**Default location:** `~/.config/macos-routes/routes.json`

Override with `--load <path>` on any script.

### Schema

```json
{
  "sets": {
    "office": [
      { "dest": "10.0.0.0/8",    "gateway": "192.168.1.1" },
      { "dest": "172.16.0.0/12", "gateway": "192.168.1.1" }
    ]
  },
  "dns": {
    "local_router": "192.168.1.1",
    "profiles": {
      "corp": {
        "domain":      "corp.example.com",
        "nameservers": ["10.1.0.53", "10.1.0.54"],
        "networks":    ["10.1.0.0/16"],
        "test_host":   "dc01.corp.example.com",
        "ping_host":   "dc01.corp.example.com"
      },
      "dev": {
        "domain":      "dev.local",
        "nameservers": ["10.2.0.1"],
        "networks":    ["10.2.0.0/24"],
        "test_host":   "devserver.dev.local"
      }
    }
  }
}
```

**Route set fields:**

| Field | Required | Description |
| ----- | -------- | ----------- |
| `dest` | ✅ | Destination in CIDR notation |
| `gateway` | ✅ | Gateway IP |
| `interface` | — | Bind to a specific interface (e.g. `en0`) |

**DNS profile fields:**

| Field | Required | Description |
| ----- | -------- | ----------- |
| `domain` | ✅ | DNS suffix written to `/etc/resolver/<domain>` |
| `nameservers` | ✅ | Array of DNS server IPs |
| `networks` | — | CIDRs to route via `local_router` when `--with-routes` is used |
| `local_router` | — | Per-profile gateway; falls back to `dns.local_router` |
| `test_host` | — | FQDN to probe with `dscacheutil` after applying |
| `ping_host` | — | FQDN to `ping -c2` after applying |

---

## Script Reference

### `dns-macos-routes.sh`

Manage macOS conditional DNS profiles. Writes `/etc/resolver/<domain>` files
so mDNSResponder uses specific nameservers for specific domains — without
changing the global DNS configuration.

```bash
# List all profiles in routes.json
dns-macos-routes.sh --list

# Show current /etc/resolver/ files
dns-macos-routes.sh --show

# Apply resolver files + add static routes for networks
sudo dns-macos-routes.sh --apply corp dev --with-routes

# Apply resolver files only (VPN handles routing)
sudo dns-macos-routes.sh --apply corp dev

# Compare JSON profile vs live state
dns-macos-routes.sh --diff corp dev

# Remove resolver files + remove their routes
sudo dns-macos-routes.sh --remove corp dev --with-routes

# Remove all /etc/resolver/ files
sudo dns-macos-routes.sh --remove-all

# Capture a live /etc/resolver/ file into the JSON
dns-macos-routes.sh --save corp --domain corp.example.com

# Backup current /etc/resolver/ to JSON archive
dns-macos-routes.sh --backup

# Restore from archive
sudo dns-macos-routes.sh --restore ~/.config/macos-routes/backups/2026-01-01T12-00-00-dns.json

# Run DNS + ping tests
dns-macos-routes.sh --test corp dev

# Flush DNS cache manually
sudo dns-macos-routes.sh --flush-cache
```

**Key options:**

| Flag | Needs root | Description |
| ---- | ---------- | ----------- |
| `--with-routes` | — | Also add/remove `networks` routes via `networksetup` |
| `--local-router <IP>` | — | Override the gateway IP for this invocation |
| `--service <svc>` | — | Override which networksetup service receives routes |
| `--load <path>` | — | Use a different routes.json file |
| `-n, --dry-run` | — | Print commands without executing |
| `-y, --yes` | — | Skip confirmation prompts |

---

### `add-macos-routes.sh`

Manage named sets of static routes stored in `routes.json`.

```bash
# Save current networksetup routes as a named set
add-macos-routes.sh --save office

# Apply a named set
sudo add-macos-routes.sh --apply office

# List all sets
add-macos-routes.sh --list

# Diff a set against the live routing table
add-macos-routes.sh --diff office

# Delete a set from JSON
add-macos-routes.sh --delete office
```

---

### `clean-macos-routes.sh`

Remove static routes from the routing table by network pattern, set name,
or all at once.

```bash
# Remove all static routes matching 10.
sudo clean-macos-routes.sh --network 10.

# Remove routes from a named set
sudo clean-macos-routes.sh --set office

# Remove all static (S-flag) routes
sudo clean-macos-routes.sh --all

# Dry-run preview
clean-macos-routes.sh --network 172. --dry-run
```

---

### `diagnose-macos-routes.sh`

Read-only diagnostics. No root required.

```bash
# Full human-readable report (routing table, DNS, VPN, ARP, /etc/resolver/)
diagnose-macos-routes.sh

# Both IPv4 and IPv6
diagnose-macos-routes.sh --all

# JSON output for scripting
diagnose-macos-routes.sh --json | jq .conditional_dns

# Ping each default gateway
diagnose-macos-routes.sh --check-gateway
```

The JSON output includes a `"conditional_dns"` key mapping each filename in
`/etc/resolver/` to its raw content.

---

### `report-macos-routes.sh`

Read-only snapshot report. No root required. Colour-aware (respects `NO_COLOR` and TTY detection).

Produces four sections in one pass:

| Section | Source |
| ------- | ------ |
| **Conditional DNS** | Every file in `/etc/resolver/` with its `nameserver`/`domain` lines |
| **Static Routes** | `networksetup -getadditionalroutes` for every service; routes cross-checked against `routes.json` and tagged `[OK]` or `[EXTRA]` |
| **Kernel Routing Table** | `netstat -rn -f inet` filtered to gateway/tunnel entries; noise (ARP, multicast, loopback) stripped |
| **VPN / Tunnel Interfaces** | Any `utun*`, `ppp*`, or `ipsec*` interface with a bound IP, plus MTU |

```bash
# Colour report (auto-detected)
report-macos-routes.sh

# Plain text (safe for logs / copy-paste)
report-macos-routes.sh --no-color

# Use a non-default routes.json for [OK]/[EXTRA] tagging
report-macos-routes.sh --routes-json /path/to/routes.json
```

**Options:**

| Flag | Description |
| ---- | ----------- |
| `--no-color` | Disable ANSI colour output |
| `--routes-json <path>` | JSON file used to classify routes as `[OK]` vs `[EXTRA]` (default: `~/.config/macos-routes/routes.json`) |

---

### `watch-macos-routes.sh`

Poll the routing table and `/etc/resolver/` for changes.

```bash
# Watch routing table (5s interval)
watch-macos-routes.sh

# Watch both routes and /etc/resolver/
watch-macos-routes.sh --watch-dns

# Auto-reapply a named set when its routes disappear
sudo watch-macos-routes.sh --restore-set office --interval 10

# Auto-reapply a DNS profile when its resolver file is deleted
sudo watch-macos-routes.sh --watch-dns --restore-dns corp

# Filter to a specific prefix
watch-macos-routes.sh --filter 10. --watch-dns

# Single diff and exit
watch-macos-routes.sh --once
```

---

### `backup-restore-routes.sh`

JSON snapshots of the routing table and optionally `/etc/resolver/`.

```bash
# Snapshot routes
backup-restore-routes.sh --backup

# Snapshot routes AND /etc/resolver/ files
backup-restore-routes.sh --backup --include-dns

# List available backups
backup-restore-routes.sh --list-backups

# Diff a backup vs current state (routes + DNS)
backup-restore-routes.sh --diff ~/.config/macos-routes/backups/2026-01-01.json --list-dns

# Restore routes
sudo backup-restore-routes.sh --restore ~/.config/macos-routes/backups/2026-01-01.json

# Restore routes AND /etc/resolver/ files
sudo backup-restore-routes.sh --restore ~/.config/macos-routes/backups/2026-01-01.json --include-dns

# Prune old backups, keep 5
backup-restore-routes.sh --prune 5
```

---

### `reset-macos-network.sh`

Full network stack reset: flushes routing table, ARP/DNS caches, cycles
interfaces, resets services to DHCP.

```bash
# Dry-run preview
sudo reset-macos-network.sh --dry-run

# Reset (with confirmation prompt)
sudo reset-macos-network.sh

# Skip prompt
sudo reset-macos-network.sh --yes

# Preserve default route after flush
sudo reset-macos-network.sh --keep-default

# Remove only static (S-flag) routes, then exit
sudo reset-macos-network.sh --flush-static

# Remove all /etc/resolver/ files, then exit
# (does NOT run as part of the default reset — opt-in only)
sudo reset-macos-network.sh --flush-dns-resolvers

# Snapshot routes before resetting
sudo reset-macos-network.sh --backup --yes
```

---

## Local Shortcut Scripts

Place site-specific shortcut scripts in the `local/` directory. This directory
is excluded from git via `.gitignore` so credentials, real IPs, and internal
domain names never leave your machine.

### Example: home office context

Create `local/home.sh`:

```bash
#!/usr/bin/env bash
# Home office: site-to-site VPN is up.
# Applies DNS resolvers AND static routes via the local router.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sudo "${SCRIPT_DIR}/dns-macos-routes.sh" \
  --apply corp dev \
  --with-routes \
  --local-router 192.168.1.1 \
  "$@"

"${SCRIPT_DIR}/dns-macos-routes.sh" --test corp dev
```

### Example: travel / client VPN context

Create `local/travel.sh`:

```bash
#!/usr/bin/env bash
# Travel: client VPN is active, handles all routing.
# Applies DNS resolvers only — no static routes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Remove any leftover home-office routes first
sudo "${SCRIPT_DIR}/dns-macos-routes.sh" --remove corp dev --with-routes "$@" || true

# Apply DNS-only (VPN handles routing)
sudo "${SCRIPT_DIR}/dns-macos-routes.sh" --apply corp dev "$@"

"${SCRIPT_DIR}/dns-macos-routes.sh" --test corp dev
```

Then make them executable and add to your shell profile if desired:

```bash
chmod +x local/home.sh local/travel.sh
```

---

## How Conditional DNS Works on macOS

macOS's `mDNSResponder` reads files from `/etc/resolver/`. Each file is named
after the DNS suffix it applies to, and contains `nameserver` lines:

```text
nameserver 10.1.0.53
nameserver 10.1.0.54
domain corp.example.com
```

With this file in place, any query for `*.corp.example.com` goes to `10.1.0.53`
(and `10.1.0.54` as a fallback). All other queries use the global DNS setting.
No restart or reload is needed — the change takes effect immediately.

This is the same mechanism used by corporate MDM profiles and VPN clients, and
it coexists with them cleanly.

---

## Split-DNS VPN Patterns

### Site-to-site VPN (home office / Meraki MX)

The VPN provides a direct Layer-3 path to the remote site. Traffic must be
explicitly routed via the **local router** (not via any VPN default route):

```text
                  ┌─────────────────────────────────────────────┐
  macOS laptop    │  Home router (Meraki MX)                    │
  ─────────────   │  ─────────────────────────────────────────  │
  DNS query for   │  MX site-to-site VPN                        │
  corp.example →  │  ─────────────────────────────────────────  │
    resolver      │  routes 10.1.0.0/16 via MX peer             │  → DNS @ 10.1.0.53
  file answers    │                                             │     (remote site)
                  └─────────────────────────────────────────────┘
```

Use `--with-routes` to configure both resolver and routing table together.

### Client VPN (travel / GlobalProtect / AnyConnect / Meraki Client VPN)

The VPN client installs its own routes. You only need conditional DNS:

```text
  ┌──────────────────────┐                        ┌─────────────────────┐
  │  macOS laptop        │   Client VPN tunnel    │  Remote site        │
  │  ─────────────────   │  ════════════════════  │  ─────────────────  │
  │  /etc/resolver/      │                        │                     │
  │  corp.example.com    │  DNS query for         │  DNS server         │
  │  → 10.1.0.53         │  corp.example  ──────→ │  10.1.0.53          │
  │                      │                        │                     │
  │  VPN client pushes   │  All other traffic     │                     │
  │  routes + resolver   │  uses global DNS  ───→ │  (not this site)    │
  └──────────────────────┘                        └─────────────────────┘
```

Use `--apply` **without** `--with-routes`. Avoid adding static routes that
conflict with what the VPN client installs.

---

## Diagnostics Quick Reference

```bash
# Quick snapshot of everything (DNS, routes, kernel table, VPN tunnels)
report-macos-routes.sh

# Same, plain text for sharing / pasting into a ticket
report-macos-routes.sh --no-color

# Are my resolver files in place?
diagnose-macos-routes.sh | grep -A10 "Conditional DNS"

# Are my static routes active?
diagnose-macos-routes.sh | grep -A10 "Additional Routes"

# Full diff of a DNS profile vs live state
dns-macos-routes.sh --diff corp

# Is DNS resolving correctly?
dscacheutil -q host -a name dc01.corp.example.com

# Are the nameservers reachable?
ping -c2 10.1.0.53
```

---

## Common Workflows

### Setting up a new site profile

```bash
# 1. Add profile to routes.json (or let --save capture a live file)
dns-macos-routes.sh --save corp --domain corp.example.com

# 2. Edit ~/.config/macos-routes/routes.json to add nameservers, networks, etc.

# 3. Apply
sudo dns-macos-routes.sh --apply corp --with-routes

# 4. Verify
dns-macos-routes.sh --diff corp
```

### Switching from home to travel

```bash
# Remove routes (DNS resolvers stay unless you --remove them)
sudo dns-macos-routes.sh --remove corp dev --with-routes
# Then connect client VPN — it will push its own routes
```

### Resetting everything cleanly

```bash
# Back up first
backup-restore-routes.sh --backup --include-dns

# Reset network stack
sudo reset-macos-network.sh --yes

# Remove conditional DNS resolvers
sudo reset-macos-network.sh --flush-dns-resolvers --yes
```

---

## Design Principles

- **No dependencies** — zsh + python3 + macOS system tools only
- **Dry-run first** — every destructive command supports `--dry-run`
- **Atomic writes** — resolver files and JSON are written to `.tmp` then `mv`'d
- **JSON-backed** — all named sets and profiles are stored in one file; easy to
  version-control separately or share across machines
- **Composable** — scripts are focused; combine them for complex workflows
- **Root-minimal** — read-only operations never require root; writes are explicit

---

## Compatibility

| macOS | Status |
| ----- | ------ |
| Sequoia (15) | ✅ Tested |
| Sonoma (14) | ✅ Tested |
| Ventura (13) | ✅ Tested |
| Monterey (12) | ⚠️ Should work; not regularly tested |
| < Monterey | ❌ Not supported |

---

## License

MIT — see [LICENSE](LICENSE) if present, otherwise consider it freely reusable.

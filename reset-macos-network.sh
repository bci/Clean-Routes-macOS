#!/usr/bin/env bash
# reset-macos-network.sh
# Flush routing table, ARP, DNS cache, restart network services, cycle interfaces,
# attempt to switch network services to DHCP (to remove persistent manual routes),
# and scan common startup locations for files that add routes.
# Run with: sudo ./reset-macos-network.sh

set -euo pipefail

info() { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*"; }

if [[ $EUID -ne 0 ]]; then
  err "Run as root (sudo)."
  exit 1
fi

info "Flushing routing table..."
if route -n flush 2>/dev/null; then
  info "Routing table flushed."
else
  warn "route -n flush unsupported; attempting best-effort deletion."
  netstat -rn | awk '/^default/ {next} $1 ~ /^[0-9]/ {print $1, $2}' | while read -r dest gateway; do
    if [[ $dest != "127.0.0.1" ]]; then
      warn "Attempting to delete route: dest=$dest gateway=$gateway"
      route delete "$dest" "$gateway" 2>/dev/null || true
    fi
  done
fi

info "Flushing ARP cache..."
arp -a | awk '{print $1}' | while read -r host; do
  [[ -n $host ]] && arp -d "$host" 2>/dev/null || true
done
info "ARP entries cleared."

info "Flushing DNS cache..."
dscacheutil -flushcache 2>/dev/null || true
killall -HUP mDNSResponder 2>/dev/null || true

info "Switching network services to DHCP to remove persistent manual configs (best-effort)..."
services=()
while IFS= read -r svc; do
  # skip disabled/empty lines
  [[ -n $svc ]] && services+=("$svc")
done < <(networksetup -listallnetworkservices 2>/dev/null | sed '1d' | sed '/^\*/d' || true)

if [[ ${#services[@]} -eq 0 ]]; then
  warn "No network services found via networksetup."
else
  for svc in "${services[@]}"; do
    info "Attempting DHCP on service: $svc"
    # Determine the hardware port/interface for the service
    device=$(networksetup -listnetworkserviceorder 2>/dev/null | awk -v svc="$svc" '
      BEGIN{RS=")\n"} $0 ~ svc {
        if (match($0, /Device: ([^,)]*)/ , m)) print m[1]
      }' || true)
    if [[ -z $device ]]; then
      # Fallback: try networksetup -getinfo to detect device name in output
      device=$(networksetup -getinfo "$svc" 2>/dev/null | awk '/^Hardware Port/ {getline; print $0; exit}' || true)
    fi
    # Try setdhcp by service name first (works regardless of device)
    if networksetup -setdhcp "$svc" >/dev/null 2>&1; then
      info "Set $svc to DHCP (service-level)."
    else
      # Fallback to device-level if we have a device name
      if [[ -n $device ]]; then
        if networksetup -setdhcp "$device" >/dev/null 2>&1; then
          info "Set $device to DHCP."
        else
          warn "Failed to set DHCP for $svc (service) or $device (device)."
        fi
      else
        warn "Could not determine device for service $svc; manual review may be required."
      fi
    fi
  done
fi

info "Enumerating and cycling physical interfaces..."
interfaces=()
while IFS= read -r line; do
  if [[ $line =~ ^([a-z0-9]+): ]]; then
    iface="${BASH_REMATCH[1]}"
    if [[ $iface == "lo0" || $iface == "awdl0" || $iface == "bridge0" || $iface == "p2p0" || $iface == "utun"* ]]; then
      continue
    fi
    interfaces+=("$iface")
  fi
done < <(ifconfig -a)

if [[ ${#interfaces[@]} -eq 0 ]]; then
  warn "No user-facing network interfaces found."
else
  info "Interfaces: ${interfaces[*]}"
  for ifc in "${interfaces[@]}"; do
    info "Cycling $ifc..."
    ifconfig "$ifc" down 2>/dev/null || warn "Failed to bring down $ifc"
    sleep 1
    ifconfig "$ifc" up 2>/dev/null || warn "Failed to bring up $ifc"
    sleep 1
    ipconfig set "$ifc" DHCP 2>/dev/null || true
  done
fi

info "Restarting network daemons..."
launchctl kickstart -k system/com.apple.mDNSResponder 2>/dev/null || warn "mDNSResponder kickstart failed"
launchctl kickstart -k system/com.apple.preferences.network 2>/dev/null || warn "Network preferences kickstart failed"

info "Scanning common startup locations for scripts that may recreate routes (searching for 'route' or 'ipconfig')..."
locations=(/etc /Library/LaunchDaemons /Library/LaunchAgents /System/Library/LaunchDaemons /System/Library/LaunchAgents /Users/*/Library/LaunchAgents /Library/Preferences /var/db /etc/rc.local)
found=0
for loc in "${locations[@]}"; do
  if [[ -e $loc ]]; then
    matches=$(grep -RIn --exclude-dir=.git -E "(^|/)(route|ipconfig)[[:space:]]" "$loc" 2>/dev/null || true)
    if [[ -n $matches ]]; then
      printf "\n[WARN] Matches in %s:\n%s\n" "$loc" "$matches"
      found=1
    fi
  fi
done
if [[ $found -eq 0 ]]; then
  info "No obvious startup scripts or plists found that reference route/ipconfig."
else
  warn "Review the above files. Remove or disable items that add routes to stop persistent routes reappearing."
fi

info "Final routing table snapshot:"
netstat -rn

info "Done. Reboot if issues persist."
exit 0

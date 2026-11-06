#!/usr/bin/env bash
# Configure an internal VLAN-aware bridge and Wi-Fi NAT on Proxmox VE.
set -euo pipefail

BRIDGE_CIDR="${BRIDGE_CIDR:-10.255.0.1/24}"
NAT_CIDR="${NAT_CIDR:-10.20.0.0/16}"
BRIDGE="${BRIDGE:-vmbr0}"
ROOT="${ROOT:-}"   # Test prefix; leave empty on a real host.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BRIDGE_IP="${BRIDGE_CIDR%/*}"
HOST_SHORT="$(hostname -s)"
HOST_FQDN="${HOST_SHORT}.home.arpa"

die() { echo "error: $*" >&2; exit 1; }
backup() { [[ ! -e "$1" ]] || cp -a "$1" "$1.bak-$STAMP"; }

if [[ -z "$ROOT" ]]; then
  [[ $EUID -eq 0 ]] || die "run as root"
  dpkg -s ifupdown2 >/dev/null 2>&1 || die "install ifupdown2 first"
  dpkg -s nftables >/dev/null 2>&1 || die "install nftables first"
fi

SERVICE_FILE="$SCRIPT_DIR/../configs/wifi-nat.service"
[[ -f "$SERVICE_FILE" ]] || die "$SERVICE_FILE not found; keep the folder layout intact"

INTERFACES="$ROOT/etc/network/interfaces"
HOSTS="$ROOT/etc/hosts"
[[ -f "$INTERFACES" ]] || die "$INTERFACES not found"
[[ -f "$HOSTS" ]] || die "$HOSTS not found"

if grep -Eq "^[[:space:]]*iface[[:space:]]+${BRIDGE}[[:space:]]" "$INTERFACES"; then
  echo "$BRIDGE already exists; leaving it unchanged"
else
  backup "$INTERFACES"
  # The source line must follow the bridge, so remove it and re-add it below.
  sed -i -E '\|^[[:space:]]*source[[:space:]]+/etc/network/interfaces\.d/\*|d' "$INTERFACES"
  cat >> "$INTERFACES" <<CONF

auto $BRIDGE
iface $BRIDGE inet static
    address $BRIDGE_CIDR
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094

source /etc/network/interfaces.d/*
CONF
  echo "added $BRIDGE"
fi

if grep -Eq "^${BRIDGE_IP//./\\.}[[:space:]].*\b${HOST_SHORT}\b" "$HOSTS"; then
  echo "hostname already points to $BRIDGE_IP"
else
  backup "$HOSTS"
  # Comment out old hostname entries, but keep any localhost line.
  sed -i -E "/^[[:space:]]*#/b; /localhost/b; /(^|[[:space:]])${HOST_SHORT}([[:space:].]|\$)/s/^/# /" "$HOSTS"
  echo "$BRIDGE_IP $HOST_FQDN $HOST_SHORT" >> "$HOSTS"
  echo "pointed hostname at $BRIDGE_IP"
fi

mkdir -p "$ROOT/etc/sysctl.d" "$ROOT/etc/systemd/system"
echo 'net.ipv4.ip_forward=1' > "$ROOT/etc/sysctl.d/99-wifi-nat.conf"

# Replace only this table. Avoid `flush ruleset`, which would affect other rules.
cat > "$ROOT/etc/wifi-nat.nft" <<CONF
table ip wifi_nat {}
delete table ip wifi_nat

table ip wifi_nat {
  chain postrouting {
    type nat hook postrouting priority srcnat;
    ip saddr $NAT_CIDR oifname "wl*" masquerade
  }
}
CONF
install -m 0644 "$SERVICE_FILE" \
  "$ROOT/etc/systemd/system/wifi-nat.service"

if [[ -z "$ROOT" ]]; then
  sysctl --system >/dev/null
  # Bring up the bridge first so a NAT failure can't leave it missing.
  ifreload -a
  ip link show "$BRIDGE" >/dev/null 2>&1 || die "$BRIDGE was not created; run: ifup -d $BRIDGE"
  systemctl daemon-reload
  systemctl enable wifi-nat.service
  systemctl restart wifi-nat.service
  systemctl is-active --quiet wifi-nat.service || die "wifi-nat failed; run: journalctl -u wifi-nat -b"
fi

echo "done: bridge and NAT ready; web UI will be at https://$BRIDGE_IP:8006 after Proxmox is installed"

# Proxmox Wi-Fi workstation

Turns a Debian 13 + Proxmox VE 9 machine into a mobile dev workstation:
Wi-Fi via DHCP on the host, and guests on an internal VLAN-aware bridge.

Wi-Fi client mode can't carry a bridged VLAN trunk, so guests are routed and
NATed out through the host's Wi-Fi connection.

```text
Wi-Fi (DHCP, NetworkManager)
        | routed + NAT
Proxmox host
        |
vmbr0 (internal, VLAN-aware, no physical ports)
   |-- VLAN 10
   |-- VLAN 20
   `-- VLAN 30
```

## Prerequisites

1. Debian 13 with Xfce and SSH. Use LUKS + LVM if you want disk encryption.
2. Proxmox VE 9 installed by following the official Debian 13 guide.
3. `ifupdown2` installed.
4. Wi-Fi managed by NetworkManager and absent from `/etc/network/interfaces`.

## Install

Review the script first, then run it as root:

```bash
sudo env BRIDGE_CIDR=10.255.0.1/24 NAT_CIDR=10.20.0.0/16 bash scripts/setup-network.sh
```

Both values are optional; those shown are the defaults. `NAT_CIDR` must cover
every guest subnet that needs internet access. Avoid ranges used by networks
you join, and reboot if the Proxmox web UI doesn't come back cleanly.

The script keeps timestamped backups of the files it changes. It:

- adds `vmbr0` to `/etc/network/interfaces`
- points the hostname at the bridge address in `/etc/hosts`
- enables IPv4 forwarding
- installs a `wifi-nat` service that masquerades guest traffic out of `wl*`

The web UI is then available at `https://<bridge-ip>:8006`.

## SDN

Choose one option under **Datacenter > SDN**:

- **Real VLAN tags:** create a VLAN zone on `vmbr0` and one VNet per tag. Add a
  router VM (OPNsense, OpenWrt or VyOS) with a trunk NIC on `vmbr0` to handle
  routing and DHCP. Its WAN side needs a separate NAT network.
- **Simple isolated subnets:** create a Simple zone with one VNet and subnet per
  segment. The host is the gateway, and there are no 802.1Q tags.

Leave **SNAT unticked** on SDN subnets. Its rule can pin the Wi-Fi address that
was current when generated, which breaks when DHCP changes it. The `wifi-nat`
service uses masquerade, which follows the current address.

## Check it

```bash
sysctl net.ipv4.ip_forward
systemctl status wifi-nat
nft list table ip wifi_nat
ip -br addr show vmbr0
```

## Remove NAT

```bash
sudo systemctl disable --now wifi-nat
sudo rm /etc/systemd/system/wifi-nat.service /etc/wifi-nat.nft
sudo systemctl daemon-reload
```

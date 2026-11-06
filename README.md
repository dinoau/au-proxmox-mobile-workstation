# Proxmox Wi-Fi workstation

A start-to-finish guide for building a mobile dev workstation with Debian 13,
Xfce and Proxmox VE 9. The host joins Wi-Fi with DHCP. Guests use an internal
VLAN-aware bridge and reach the internet through routed NAT.

This guide follows the official
[Install Proxmox VE on Debian 13 Trixie](https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_13_Trixie)
page, with the changes needed for a Wi-Fi laptop. Check that page for updates
before you start.

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

Wi-Fi client mode can't carry a bridged VLAN trunk, so guests can't connect
directly to the Wi-Fi network at Layer 2.

## Differences from the official guide

| Official guide | This guide | Why |
| --- | --- | --- |
| Static IP set in Debian expert mode | Wi-Fi DHCP, with the hostname pinned to `vmbr0` | The Wi-Fi address changes between networks |
| Desktop not necessary | Xfce installed | This is also a workstation |
| First NIC added to `vmbr0` | `vmbr0` has no physical ports | Wi-Fi can't be bridged |
| DNS managed in the Proxmox UI | DNS managed by NetworkManager | DNS must follow each Wi-Fi network |
| Subscription key uploaded | No-subscription repository kept | Only change this if you have a subscription |

Proxmox says a supported installation should use its ISO, and that installing
on Debian makes sense in some cases, such as a custom partition layout.

## 1. Prepare

1. Back up the machine. The Debian install below erases the disk.
2. In the firmware settings, **disable Secure Boot**. The Proxmox kernel can fail
   with `error: bad shim signature` if it stays on.
3. In the firmware settings, enable Intel VT-x or AMD-V, plus VT-d or AMD-Vi if
   you plan to use PCI passthrough.
4. Download `debian-13.x.x-amd64-netinst.iso` from
   [debian.org](https://www.debian.org/distrib/netinst) and write it to a USB drive.
5. Keep a USB Ethernet adapter or USB phone tethering available as a backup connection.

## 2. Install Debian

1. Boot the USB drive and choose **Graphical install**.
2. Connect to Wi-Fi when prompted.
3. Set a short hostname, such as `pve`.
4. **Set a root password.** Proxmox's web UI uses it for the first login.
5. Create your normal user.
6. For encryption, choose **Guided - use entire disk and set up encrypted LVM**.
7. At **Software selection**, tick only:
   - Debian desktop environment
   - Xfce
   - SSH server
   - Standard system utilities

   Leave GNOME, Debian Blend, the other desktops and web server unticked.
8. Install GRUB, then reboot and remove the USB drive.

## 3. Set up root and your sudo user

Log in to Xfce as your normal user. Don't run the desktop as root.

Open **Applications > Terminal Emulator** and become root. Keep the dash in
`su -`, because it sets up root's full command path.

```bash
su -
```

If Xfce won't start, press `Ctrl+Alt+F3`, log in as root, and use the commands
below. Press `Ctrl+Alt+F7` to return to Xfce. If that shows a blank screen, try
`Ctrl+Alt+F1`.

Add sudo access, replacing `YOUR_USER`:

```bash
apt update
apt install -y sudo
usermod -aG sudo YOUR_USER
```

Log out of Xfce and back in so the group change applies, then check it:

```bash
groups
sudo -v
sudo -i
```

`sudo -i` gives you a root shell. **Run all remaining commands in this guide as root.**

If you left the root password blank during install, sudo is already set up and
root has no password. Set one now, because the web UI needs it:

```bash
sudo passwd root
```

Debian normally blocks SSH password login for root, so connect as your normal
user and then run `sudo -i`.

## 4. Make Wi-Fi start at boot

Remove any Wi-Fi settings from `/etc/network/interfaces`. Keep the `lo` entries.

```bash
nano /etc/network/interfaces
```

Connect with NetworkManager, replacing `YOUR_SSID`:

```bash
systemctl enable --now NetworkManager
nmcli device wifi list
nmcli --ask device wifi connect "YOUR_SSID"
```

Make the connection available before anyone logs in. The profile name is usually
the SSID, and `nmcli connection show` lists it.

```bash
nmcli connection modify "YOUR_SSID" connection.permissions "" \
  802-11-wireless-security.psk-flags 0 connection.autoconnect yes
```

Then confirm Wi-Fi is up and disable the install media in APT:

```bash
ping -c 3 deb.debian.org
sed -i 's/^deb cdrom:/# deb cdrom:/' /etc/apt/sources.list
```

## 5. Create the bridge and pin the hostname

Proxmox needs the hostname to resolve to a non-loopback address **before** its
packages are installed. This step uses `vmbr0`, so the address stays the same on
every Wi-Fi network.

Install the prerequisites. `ifupdown2` replaces `ifupdown`, which is expected.

```bash
apt install -y ifupdown2 nftables bridge-utils
```

From this repository folder, review `scripts/setup-network.sh`, then run:

```bash
env BRIDGE_CIDR=10.255.0.1/24 NAT_CIDR=10.20.0.0/16 bash scripts/setup-network.sh
```

Both values are optional, and those shown are the defaults. `NAT_CIDR` must
cover every guest subnet that needs internet access. Avoid ranges used by
networks you join.

The script keeps timestamped backups of the files it changes. It adds `vmbr0`,
points the hostname at the bridge address in `/etc/hosts`, enables IPv4
forwarding, and installs the `wifi-nat` service.

Check the result:

```bash
hostname --ip-address
ip -br addr show vmbr0
systemctl status wifi-nat --no-pager
```

`hostname --ip-address` should include `10.255.0.1`, not only a `127.x.x.x`
address. `vmbr0` may show `DOWN` until a guest connects, which is normal.

## 6. Add the Proxmox repository

```bash
cat > /etc/apt/sources.list.d/pve-install-repo.sources << EOL
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOL
```

Add the repository key:

```bash
apt install -y wget
wget https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
  -O /usr/share/keyrings/proxmox-archive-keyring.gpg
```

Verify it. **Stop if either result doesn't match.**

```bash
sha256sum /usr/share/keyrings/proxmox-archive-keyring.gpg
# 136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45

md5sum /usr/share/keyrings/proxmox-archive-keyring.gpg
# 77c8b1166d15ce8350102ab1bca2fcbf
```

Update the system:

```bash
apt update && apt full-upgrade
```

## 7. Install and boot the Proxmox kernel

This has to happen before the main Proxmox packages, because some of them depend
on Proxmox kernel features.

```bash
apt install proxmox-default-kernel
systemctl reboot
```

After rebooting, log in, run `sudo -i`, and check the kernel and Wi-Fi:

```bash
uname -r
ping -c 3 deb.debian.org
```

`uname -r` should end in `-pve`. **Don't continue if Wi-Fi fails.** Reboot, open
**Advanced options for Debian** in GRUB, and start the Debian kernel. Then see
[Troubleshooting](#troubleshooting).

## 8. Install Proxmox VE

Read apt's removal list before you confirm. Stop if it wants to remove Xfce,
NetworkManager or your Wi-Fi firmware without a replacement.

```bash
apt install proxmox-ve postfix open-iscsi chrony
```

For the Postfix prompts, choose **Satellite system** if you have a mail relay.
Otherwise choose **Local only** and keep the default system name.

### Replace systemd-timesyncd

Proxmox recommends against `systemd-timesyncd` on servers. Installing `chrony`
normally removes it. If it's still present, remove it and check chrony:

```bash
dpkg -l systemd-timesyncd 2>/dev/null | grep '^ii' && apt purge -y systemd-timesyncd
systemctl enable --now chrony
chronyc tracking
timedatectl status
```

`timedatectl` should show `System clock synchronized: yes`. This can take a
minute, and needs a working network connection.

## 9. Remove the Debian kernel and os-prober

Proxmox says the Debian kernel **must** be removed, because keeping it can cause
trouble with upgrades.

First confirm that you're on a `-pve` kernel and Wi-Fi works:

```bash
uname -r
ping -c 3 deb.debian.org
```

Remove the Debian kernel and update GRUB:

```bash
apt remove linux-image-amd64 'linux-image-6.12*'
update-grub
```

Remove `os-prober` unless this machine dual-boots. It can scan VM disks and
create unwanted boot entries.

```bash
apt remove os-prober
```

Reboot and confirm everything comes back:

```bash
systemctl reboot
```

```bash
uname -r
pveversion
systemctl --failed
```

## 10. First web UI login

1. In Firefox on the workstation, open `https://10.255.0.1:8006`.
2. Accept the self-signed certificate warning.
3. Log in as `root` with the **Linux PAM** realm.
4. Go to **your node > Updates > Repositories** and disable the enterprise
   repositories, unless you have a subscription. Keep `pve-no-subscription`.
5. Go to **Datacenter > Storage > local > Edit** and add **Disk image** and
   **Container** to Content. The Debian install doesn't create `local-lvm`.

If you buy a subscription later, upload the key and then run:

```bash
rm /etc/apt/sources.list.d/pve-install-repo.sources
```

Optionally, give your Linux user Proxmox admin access:

```bash
pveum user add YOUR_USER@pam
pveum acl modify / --users YOUR_USER@pam --roles Administrator
```

Leave DNS out of the node's **System > DNS** page. NetworkManager needs to update
`/etc/resolv.conf` on each Wi-Fi network.

## 11. Set the laptop power behavior

Xfce: open **Settings > Power Manager** and set the lid and idle actions as you
want them. This stops the laptop from suspending while guests are running:

```bash
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/lid.conf << EOL
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOL
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

Reboot to apply the lid setting.

## 12. Set up guest networking

Choose an option in **Datacenter > SDN**. Leave **SNAT unticked** in both. Its
rule can pin the Wi-Fi address that was current when it was generated, which
breaks when DHCP changes it. `wifi-nat` uses masquerade, which follows the
current address.

### Option A: simple isolated subnets

This is the lightest option. The host is the gateway, and there are no 802.1Q tags.

1. Install DHCP support, and turn off the default dnsmasq service:

   ```bash
   apt install -y dnsmasq
   systemctl disable --now dnsmasq
   ```

2. Go to **SDN > Zones > Add > Simple**. Set ID `dev`, IPAM `pve`, and tick
   **automatic DHCP** (shown under advanced options).
3. Go to **SDN > VNets > Create**. Set name `dev10` and zone `dev`.
4. Select `dev10`, then create a subnet: `10.20.10.0/24`, gateway `10.20.10.1`,
   with a DHCP range such as `10.20.10.100` to `10.20.10.200`.
5. Go to **SDN** and click **Apply**.
6. Attach a guest NIC to `dev10` with IPv4 set to DHCP.

Repeat with a new VNet for each segment. The host can route between these
subnets, so add firewall rules if they need to stay separate.

### Option B: real VLAN tags

This option needs a small router VM, such as OPNsense, OpenWrt or VyOS.

1. Follow Option A to make a VNet named `wan`, with subnet `10.20.0.0/24` and
   gateway `10.20.0.1`.
2. Go to **SDN > Zones > Add > VLAN**. Set ID `lab` and bridge `vmbr0`.
3. Create a VNet for each VLAN, such as `vlan10` with tag `10`, in zone `lab`.
4. Click **Apply** on the **SDN** page.
5. Give the router VM a WAN NIC on `wan`, using static address `10.20.0.2/24`
   and gateway `10.20.0.1`.
6. Give the router VM a trunk NIC on `vmbr0` with no VLAN tag, then create its
   VLAN interfaces, DHCP and NAT.
7. Attach each guest to the matching VNet.

### Test a guest

Create a Debian LXC, attach it to a VNet, and run this inside it:

```bash
ip -br addr
ip route
ping -c 3 1.1.1.1
ping -c 3 deb.debian.org
```

If the IP ping works but the name lookup fails, set a DNS server in the guest or
in its DHCP settings.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| `error: bad shim signature` | Disable Secure Boot. |
| `ipcc_send_rec[1] failed: Connection refused` | Review `/etc/hosts`, then run `hostname --ip-address`. |
| Wi-Fi fails on the `-pve` kernel | Boot the Debian kernel if it's still installed, then run `lspci -nnk \| grep -iA3 network` and `journalctl -b -1 -k \| grep -iE 'firmware\|wifi\|iwl\|mt7\|ath\|rtw'`. |
| DNS fails on the host | Check `/etc/resolv.conf` and `nmcli device show`. Don't add `resolvconf`, and don't set DNS in the Proxmox UI. |
| Wi-Fi only connects after login | Repeat the `nmcli connection modify` command in step 4. |
| Guests have no internet | Check `sysctl net.ipv4.ip_forward`, `nft list table ip wifi_nat`, and that the guest subnet is inside `NAT_CIDR`. |
| Web UI won't open | Run `systemctl status pveproxy`, then try `https://127.0.0.1:8006`. |
| Network settings are wrong | Restore the latest `/etc/network/interfaces.bak-*` or `/etc/hosts.bak-*` file, then run `ifreload -a`. |

## Remove NAT

```bash
systemctl disable --now wifi-nat
rm /etc/systemd/system/wifi-nat.service /etc/wifi-nat.nft
systemctl daemon-reload
```

## References

- [Install Proxmox VE on Debian 13 Trixie](https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_13_Trixie)
- [Setup Simple Zone With SNAT and DHCP](https://pve.proxmox.com/wiki/Setup_Simple_Zone_With_SNAT_and_DHCP)
- [Proxmox VE network configuration](https://pve.proxmox.com/wiki/Network_Configuration)

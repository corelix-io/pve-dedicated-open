# OVH Provider Guide

This page covers everything OVH-specific that
[`pve-dedicated`](../../README.md) needs you (or your CI) to know.
OVH's networking has several quirks -- gateway model, IPv6 gateway
form, Virtual MACs and vRack -- that are fully encoded in
[`lib/providers/ovh.sh`](../../lib/providers/ovh.sh) and exposed via
the OVH-specific CLI flags.

For the multi-provider overview, start at
[`README.md`](../../README.md). For the cross-cutting architecture,
read [`.claude/docs/ARCHITECTURE.md`](../../.claude/docs/ARCHITECTURE.md).

## Supported Ranges

| Range | Gateway model | Typical NIC | Notes |
|-------|---------------|-------------|-------|
| [Eco](https://eco.ovhcloud.com/) / [Kimsufi](https://eco.ovhcloud.com/kimsufi/) / [SoYouStart](https://eco.ovhcloud.com/soyoustart/) | `classic` | `eno1`, `enp*` | In-subnet `/24`-style gateway. |
| [Rise](https://www.ovhcloud.com/en/bare-metal/rise/) | `classic` | `eno1`, `enp*` | In-subnet gateway. |
| [Advance](https://www.ovhcloud.com/en/bare-metal/advance/) | `scale` | `eno*`, `ens*f0` | `/32` host + on-link `100.64.0.1`. Pass `--ovh-gateway-model scale`. |
| [Scale](https://www.ovhcloud.com/en/bare-metal/scale/) | `scale` | Multiple NICs | `/32` + `100.64.0.1`. vRack-ready. |
| [High Grade](https://www.ovhcloud.com/en/bare-metal/high-grade/) | `scale` | Multiple NICs | `/32` + `100.64.0.1`. vRack-ready. |

`pve-dedicated` auto-detects the gateway model when
`--ovh-gateway-model auto` (the default) is used: if the detected
gateway equals `100.64.0.1`, the installer switches to `scale`; any
other value is treated as `classic`. You can force the decision with
`--ovh-gateway-model classic|scale`.

## Enabling Rescue Mode

1. Log in to the [OVHcloud Manager](https://www.ovh.com/manager/).
2. Go to **Bare Metal Cloud** > your server.
3. Under **Netboot**, pick **Rescue** and save.
4. Under **Status**, click **Restart**.
5. Wait ~2 minutes. OVH emails the rescue root password and IP (if
   the server kept its IP the rescue email still arrives with a new
   password).
6. SSH in as `root`.

### Rescue environment facts

- Debian-based minimal image, loaded via PXE/netboot.
- Marker file: `/etc/ovhrescue` (or `/etc/ovh-rescue`).
- The motd and DNS typically mention OVH, and hostname often contains
  `rescue` or `ovh`. All four are used by
  [`ovh_check_rescue`](../../lib/providers/ovh.sh) as fallbacks.
- NIC in rescue is typically `eth0`; the installed system uses
  `eno*`, `enp*` or `ens*`. See the "NIC naming" section below.
- `predict-check` does **not** exist (that is a Hetzner tool).
- `/sys/class/net/<iface>/address` and `ip link show` are the
  reliable source of truth for the physical MAC.
- `/root` (and `/`) are on the rescue's in-memory `rootfs`. `df`
  reports it as `0 0 0` because the kernel doesn't track its size,
  but writes still succeed up to whatever spare RAM allows. The
  installer auto-detects this (see "Workspace auto-relocation"
  below) and switches to a sized tmpfs at `/mnt/pve-dedicated-work`
  before downloading the 1.7 GB Proxmox ISO. No manual intervention
  needed.

### Workspace auto-relocation

The installer expects at least **5 GiB free** in the working
directory because `proxmox-auto-install-assistant` needs the original
ISO (~1.7 GB) plus a `.tmp` copy (~1.7 GB) plus generated configs
plus logs. OVH rescue's `rootfs` does not satisfy this.

In phase 7 (Dependencies), [`iso_ensure_workspace_capacity`](../../lib/iso.sh)
calls `df -P -B1` on `PVE_WORKING_DIR`. If it reports less than 5 GiB
free (or returns garbage), the installer automatically:

1. Mounts a tmpfs at `/mnt/pve-dedicated-work` sized to
   `min(16 GiB, max(8 GiB, RAM/4))`.
2. Migrates any already-downloaded `pve.iso` (saving a re-download).
3. Updates `PVE_WORKING_DIR` to the new mount.
4. Continues with the install.

The mount persists until the rescue session ends (next reboot) so
that install logs stay readable for support. To opt out, pre-set
`PVE_WORKING_DIR` to a path that already has enough room (e.g.,
`PVE_WORKING_DIR=/tmp ./pve-dedicated.sh ...`); when the existing
path has >= 5 GiB free, no tmpfs is mounted.

### IMPORTANT: Netboot toggle is sticky

OVH's rescue is delivered through the netboot selector, and the
selector stays set on "Rescue" until you change it. If you skip step
4 below, the server will boot back into rescue after every reboot.

## Post-Install Boot Toggle

After the installer finishes, **and before you reboot out of rescue**:

1. OVHcloud Manager > your server > **Netboot**.
2. Select **Boot from the hard disk**.
3. Click **Save**.
4. Then restart the server (`Status > Restart` or a shell `reboot`).

The install report prints this reminder at the end of the run.

## NIC Naming Differences

OVH's rescue image and the installed kernel can resolve the same NIC
to different names. In rescue it is almost always `eth0`; post
install it is typically `eno1`, `eno1np0`, `enp5s0f0`, `ens9f0np0`,
etc.

`ovh_predict_iface` resolves this by reading udev's `ID_NET_NAME_PATH`
(and falling back to `ID_NET_NAME_SLOT`) on the currently active NIC
in rescue:

```bash
udevadm info /sys/class/net/eth0 | grep 'ID_NET_NAME_'
# ID_NET_NAME_PATH=enp5s0f0
# ID_NET_NAME_SLOT=ens9f0np0
```

### MAC-based identification

The MAC stays the same across rescue and the installed system, so it
is the most reliable way to identify the public NIC. The installer
captures `PVE_MAC_ADDRESS` during network detection and uses it
inside initramfs hooks on premium builds (see
[`docs/premium/luks.md`](../premium/luks.md)) to find the correct
NIC regardless of its name.

To match a MAC to the OVH-known public IP, use the Manager:
Bare Metal Cloud > your server > **Network interfaces**.

## Gateway Models

OVH exposes two very different L3 topologies depending on the range.

### `classic` -- in-subnet `/24`-style gateway

Used on Eco, Kimsufi, SoYouStart and Rise. Your main IP sits inside
a `/24` (or similar) and the gateway address is inside the same
subnet. This is the "normal" behaviour most bare-metal customers
expect.

`/etc/network/interfaces` on `vmbr0`:

```ini
auto vmbr0
iface vmbr0 inet static
    address <PUBLIC_IP>/<MASK>
    gateway <GATEWAY_IN_SUBNET>
    bridge-ports <IFACE>
    bridge-stp off
    bridge-fd 0
```

### `scale` -- `/32` host + on-link `100.64.0.1`

Used on Advance, Scale and High Grade. Your main IP is handed out
as a host `/32`, and the gateway is the link-scoped
`100.64.0.1` (RFC6598 shared-address space) reachable only via
`pointopoint`. This lets OVH move IPs between machines without
renumbering a whole subnet.

`/etc/network/interfaces` on `vmbr0` (NAT mode):

```ini
auto vmbr0
iface vmbr0 inet static
    address <PUBLIC_IP>/32
    gateway 100.64.0.1
    bridge-ports <IFACE>
    bridge-stp off
    bridge-fd 0
    pointopoint 100.64.0.1
```

Pass `--ovh-gateway-model scale` explicitly in unattended runs on
these ranges, or leave it at `auto` and let the installer detect the
gateway. Using `classic` on a Scale/HG/Advance box will yield an
unreachable server because `100.64.0.1` is not in your subnet.

## IPv6

OVH does not use link-local `fe80::1` as the gateway. Instead, the
gateway is derived from your `/64` prefix by promoting the low-order
byte of the `/56` parent prefix to `0xFF` and padding with
`FF:FF:FF:FF`.

Example: given `2001:41d0:1510:1c89::/64`, the gateway is:

```
2001:41d0:1510:1cFF:FF:FF:FF:FF
```

This form is computed by
[`ovh_compute_ipv6_gateway`](../../lib/providers/ovh.sh) and applied
with explicit `ip -6 route add` statements (the default route cannot
be configured with `gateway` alone because OVH's v6 gateway is not
on-link):

```ini
iface vmbr0 inet6 static
    address <PREFIX>::1/64
    post-up  /sbin/ip -f inet6 route add <PREFIX>:FF:FF:FF:FF:FF dev vmbr0 || true
    post-up  /sbin/ip -f inet6 route add default via <PREFIX>:FF:FF:FF:FF:FF || true
    pre-down /sbin/ip -f inet6 route del default via <PREFIX>:FF:FF:FF:FF:FF || true
    pre-down /sbin/ip -f inet6 route del <PREFIX>:FF:FF:FF:FF:FF dev vmbr0 || true
```

References:
[OVH IPv6 configuration guide](https://help.ovhcloud.com/csm/en-gb-dedicated-servers-network-ipv6?id=kb_article_view&sysparm_article=KB0043731)
and the Proxmox Forum threads on OVH IPv6 routing.

## Additional IPs

OVH sells two different kinds of extra IPs:

- **Additional IPs** bought on classic ranges. These **require a
  Virtual MAC (vMAC)** configured in the OVH Control Panel for each
  VM that uses them. Without a vMAC, egress from the VM is blocked by
  OVH's anti-spoofing rules -- same semantics as Hetzner's IP/MAC
  binding.
- **vRack IP blocks** (assigned to a vRack). These do **not** need a
  vMAC; they live on the private vRack network.

Configure Virtual MACs in the Manager:
Bare Metal Cloud > **IPs** > select the IP > **Add a virtual MAC**.
Use the MAC it shows as the guest NIC MAC in Proxmox
(`qm set <vmid> --net0 virtio=AA:BB:CC:DD:EE:FF,bridge=vmbr0`).

### Routed mode for additional IPs

On all OVH ranges, the simplest way to route additional IPs to VMs
is `--network-mode routed` with `--ovh-additional-ips`:

```bash
./pve-dedicated.sh --provider ovh --ovh-gateway-model scale \
    --network-mode routed \
    --ovh-additional-ips "203.0.113.10,203.0.113.11,203.0.113.12"
```

This produces a `vmbr0` bridge with `bridge-ports none` and adds
`ip route add <ip>/32 dev vmbr0` lines for each additional IP. VMs
bind the additional IP directly and egress via the host's MAC (so
no vMAC is needed even on classic ranges).

If you instead want the VMs to own the public IP at L2, use
`--network-mode bridged` and assign vMACs per VM NIC.

## vRack

vRack is OVH's private Layer 2 network between your services. To
attach your Proxmox node to a vRack, you need:

1. An existing vRack configured in the OVH Manager with the server
   attached.
2. The name of the **second NIC** inside your server that is wired to
   the vRack (e.g. `eno2`, `ens9f1np0`). OVH documents which NIC is
   "public" vs "private" in your server's technical spec sheet; in
   rescue you can also see both via `ip link show`.

Then pass it to the installer:

```bash
./pve-dedicated.sh --provider ovh \
    --ovh-vrack-interface eno2 \
    --ovh-vrack-ip 10.42.0.10/24
```

`pve-dedicated` renders a VLAN-aware `vmbr2` bridge bound to that
NIC:

```ini
iface <VRACK_IFACE> inet manual

auto vmbr2
iface vmbr2 inet static
    address <VRACK_IP>/<MASK>
    bridge-ports <VRACK_IFACE>
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
```

VMs that need to sit on the vRack simply attach to `vmbr2` (optionally
with a VLAN tag for multi-tenant setups).

## Network Topologies

`pve-dedicated` supports three modes on OVH, selected with
`--network-mode`:

- `nat` (default) -- `vmbr0` holds the main public IP; `vmbr1` is a
  private NAT bridge for VMs. Same shape as Hetzner NAT, with the
  gateway/IPv6 quirks handled by
  [`ovh_render_interfaces_nat`](../../lib/providers/ovh.sh).
- `routed` -- physical NIC keeps the public IP as `/32`; `vmbr0` has
  no `bridge-ports`; additional IPs are `ip route add`'ed on it.
- `bridged` -- physical NIC is `inet manual`; `vmbr0` holds the
  public IP and bridges to the NIC. VM NICs need vMACs for public IPs
  on classic ranges; on vRack blocks they do not.

## Example `/etc/network/interfaces` (OVH NAT, scale model)

Produced by
[`ovh_render_interfaces_nat`](../../lib/providers/ovh.sh) on an HG /
Scale / Advance range.

```ini
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

iface lo inet6 loopback

iface <IFACE> inet manual

auto vmbr0
iface vmbr0 inet static
    address <PUBLIC_IP>/32
    gateway 100.64.0.1
    bridge-ports <IFACE>
    bridge-stp off
    bridge-fd 0
    pointopoint 100.64.0.1

iface vmbr0 inet6 static
    address <PREFIX>::1/64
    post-up  /sbin/ip -f inet6 route add <PREFIX>:FF:FF:FF:FF:FF dev vmbr0 || true
    post-up  /sbin/ip -f inet6 route add default via <PREFIX>:FF:FF:FF:FF:FF || true
    pre-down /sbin/ip -f inet6 route del default via <PREFIX>:FF:FF:FF:FF:FF || true
    pre-down /sbin/ip -f inet6 route del <PREFIX>:FF:FF:FF:FF:FF dev vmbr0 || true

auto vmbr1
iface vmbr1 inet static
    address <PRIVATE_IP>/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   iptables -t nat -A POSTROUTING -s '<PRIVATE_SUBNET>' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '<PRIVATE_SUBNET>' -o vmbr0 -j MASQUERADE
    post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
    post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
```

## DNS Defaults

When `--dns` is not set, the installer applies OVH's defaults:

- `213.186.33.99` (OVH recursor)
- `1.1.1.1` (Cloudflare, for resilience)

You can override with any recursor you prefer
(`--dns "9.9.9.9 1.0.0.1"`).

## Network Firewall

OVH offers a stateful firewall at the network edge (per IP). Activate
it before exposing Proxmox:

1. OVHcloud Manager > Bare Metal Cloud > **IP**.
2. Click the IP > **Network firewall**.
3. Activate the firewall.
4. Create ALLOW rules for TCP 22 and TCP 8006 from your management
   IPs, plus any VM ports you want to expose.
5. Add a final DROP rule.
6. (Optional) Enable the **Anti-DDoS Game** profile if your workload
   tolerates its latency profile (useful for UDP-heavy game servers;
   slightly higher RTT for general TCP).

Combine this with the Proxmox built-in firewall (Datacenter and Node
levels) for defence in depth.

## OVH Control Panel Checklist

The report printed at the end of a successful install
([`ovh_post_install_notes`](../../lib/providers/ovh.sh)) summarises
the must-do items:

1. Switch netboot back to **Boot from the hard disk**.
2. Reboot the server from the Manager.
3. If using bridged or routed mode, add a vMAC per VM public IP
   (classic ranges only).
4. Activate the **Network firewall** and set an ALLOW-ALLOW-DROP
   rule chain.

## Upstream References

- [OVH netboot / rescue](https://help.ovhcloud.com/csm/en-gb-dedicated-servers-rescue-mode?id=kb_article_view&sysparm_article=KB0043663)
- [OVH IP configuration for dedicated servers](https://help.ovhcloud.com/csm/en-gb-dedicated-servers-network-ipv4?id=kb_article_view&sysparm_article=KB0043732)
- [OVH IPv6 configuration](https://help.ovhcloud.com/csm/en-gb-dedicated-servers-network-ipv6?id=kb_article_view&sysparm_article=KB0043731)
- [OVH Virtual MAC addresses](https://help.ovhcloud.com/csm/en-gb-dedicated-servers-network-virtual-mac?id=kb_article_view&sysparm_article=KB0043735)
- [OVH vRack overview](https://help.ovhcloud.com/csm/en-gb-dedicated-servers-vrack-configuration?id=kb_article_view&sysparm_article=KB0043734)
- [Proxmox VE on OVH dedicated (community tutorial)](https://help.ovhcloud.com/csm/en-gb-dedicated-servers-proxmox-ve?id=kb_article_view&sysparm_article=KB0043775)
- [Proxmox Forum: OVH /32 with 100.64.0.1 gateway](https://forum.proxmox.com/threads/ovh-proxmox-with-100-64-0-1-as-gateway.97054/)

For provider-aware troubleshooting (rescue mount on ZFS, netboot
stuck on rescue, gateway mis-classification), see the OVH sections
of
[`.claude/docs/TROUBLESHOOTING.md`](../../.claude/docs/TROUBLESHOOTING.md).

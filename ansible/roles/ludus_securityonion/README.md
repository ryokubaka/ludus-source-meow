# ludus_securityonion

Attaches a sniff `net1` on Proxmox during Ludus deploy (Proxmox API via same env vars
as `range-management/proxmox.py`), waits for the guest to see it, then runs
Security Onion `so-setup iso <type>-net` (default **standalone-net**).

Works with plain Ludus CLI/API deploy. No LUX required.

## Requirements

- VM built from `securityonion-2.4-x64-template`, `securityonion-3-x64-template`, or `securityonion-3.3-x64-template`
- Role run during **Ludus range deploy** (Ludus injects `PROXMOX_*` into ansible-playbook)
- Uses Ludus extra vars: `range_second_octet`, `vm_target_nodes`, `inventory_hostname`
- Internet on the SO management VLAN for Standard install pulls (unless airgap images present)

## Ludus-provided inputs (no manual config)

| Source | Used for |
|---|---|
| `PROXMOX_URL`, `PROXMOX_USERNAME`, `PROXMOX_TOKEN`, `PROXMOX_SECRET` | Proxmox API auth |
| `range_second_octet` / `LUDUS_RANGE_NUMBER` | `vmbr10XX` bridge name |
| `vm_target_nodes` / `PROXMOX_NODE` | Proxmox node lookup |
| `inventory_hostname` | VM name in Proxmox |

## Role variables

| Variable | Default | Purpose |
|---|---|---|
| `ludus_so_attach_sniff_nic` | `true` | Attach `net1` via Proxmox API before waiting |
| `ludus_so_sniff_tag` | `10` | 802.1Q tag on sniff NIC (targets VLAN in SO labs) |
| `ludus_so_sniff_mtu` | `""` | Optional Proxmox `net1` MTU (empty = inherit Ludus `vmbr`, usually 1500) |
| `ludus_so_bond_mtu` | `1500` | Monitor/bond MTU for `so-setup` (virtio labs; do not use 9000 without jumbo bridge) |
| `ludus_so_install_type` | `standalone` | `standalone` or `eval` |
| `ludus_so_expect_version` | `""` | Require the ISO `VERSION` to start with this release (`3.3` matches `3.3.0`). Empty skips the check. |
| `ludus_so_setup_profile_suffix` | `net` | Profile suffix for so-setup |
| `ludus_so_sniff_wait_timeout` | `1800` | Seconds to wait for sniff NIC in guest |
| `ludus_so_web_user` | `onionadmin@ludus.local` | SOC user (TESTING profile) |
| `ludus_so_web_password` | `MeowMeow123` | SOC password (lab default) |
| `ludus_so_allow_cidr` | `""` | Unused. Analyst/SOC is always `0.0.0.0/0`; the range router enforces access |
| `ludus_so_require_dns` | `true` | Fail before `so-setup` if SO repo hostnames do not resolve |
| `ludus_so_range_number_override` | `""` | Rare fallback if range number extra var missing |
| `ludus_so_heal_sniff_bond` | `true` | Enslave sniff NIC to `bond0` + systemd oneshot (sensors listen on bond0) |
| `ludus_so_reboot_if_needed` | `true` | Reboot when `needs-restarting` or the so-soc reboot flag says the guest still needs one |
| `ludus_so_reboot_timeout` | `900` | Seconds to wait for SSH after that reboot |

## DNS and internet (common setup failure)

`so-setup` pulls packages from `repo.securityonion.net` / `repo-alt.securityonion.net`.
The SO VM must resolve those via **Ludus range router DNS**:

`10.<range_number>.<vlan>.254` (example: vlan 10 → `10.1.10.254`, vlan 20 → `10.1.20.254`)

**Most common failure: Ludus Testing Mode is ON.** Testing blocks outbound
internet/DNS on the range router (by design) — `so-setup` cannot reach
`repo.securityonion.net` until testing is stopped (or those hosts are allowlisted).

**Fix order:**

1. **Stop Testing Mode** before deploy / so-setup (LUX → Testing, or Ludus `testing/stop`).
2. If testing must stay on, allowlist `repo.securityonion.net` and `repo-alt.securityonion.net`.
3. If the SO VM has a `testing:` block, set `block_internet: true` (Ludus requires
   the key). Never use `false` to bypass isolation for so-setup.

Quick check from the SO VM:

```bash
ping -c1 10.1.10.254                    # router reachable?
dig @10.1.10.254 repo.securityonion.net # router forwarding DNS?
getent hosts repo.securityonion.net     # system resolver
```

## Notes

Official Security Onion does not support automated installs; this role uses the
internal CI `test_profile` path (`TESTING=true`) for lab automation only.

Ludus attaches only **one** NIC per VM at clone time; this role adds the second
(sniff) NIC via Proxmox API before `so-setup`. Ludus range bridges use **MTU 1500**;
virtio NICs cannot exceed the bridge MTU, so **`mtu=9000` on net1 will fail** in guest.
SO may create `bond0` at jumbo MTU — this role passes **`MTU=1500`** to `so-setup`
for virtio labs. A failed/partial install can leave **`bond0`** behind; the role removes
it before `so-setup` so the TESTING profile selects **`ens18`** (mgmt) not **`bond0`**.
Bridge `ageing_time 0` is set on the Proxmox node that owns `vmbr10XX`.
The role tries a direct sysfs write, then `sudo -n`, then `ssh root@` the node.
Range users have neither sudo nor a root SSH key, and the API console stops at
a login prompt. The Proxmox API token from the deploy then updates every Linux
bridge with `bridge-ports-condone-regex` so `ifreload` keeps live VM taps, sets
`bridge-ageing 0` on the range bridge only, and reloads networking. The task
succeeds only when that bridge reads `0`, every bridge still has the taps it
had, and `vmbr` addresses are still present. Other ranges stay learning bridges.
Hub mode floods VLAN 10 frames to the sniff NIC.

Boot highstate is what marks the grid node Fault. This role creates the Fleet Server policy `FleetServer_<hostname>` (Elasticsearch output and the fleet_server integration) and installs `ludus-so-fleet-policy.service` so that exists before `so-boot-highstate` waits on port 8220. It also patches `so-elasticsearch-pipelines` to retry a busy Elasticsearch instead of failing the highstate when `logs-pfsense.log-1.25.4` is not acknowledged on the first tries.

After `so-setup`, zeek/suricata listen on **`bond0`**. If the sniff NIC (`ens19`) is not
enslaved, `bond0` stays NO-CARRIER and NSM sees no range traffic. This role runs
`ensure-sniff-bond.yml` after setup and on redeploy (marker present) to enslave the
sniff NIC and install `ludus-so-enslave-sniff.service` for boot persistence.

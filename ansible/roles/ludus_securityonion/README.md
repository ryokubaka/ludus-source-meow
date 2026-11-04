# ludus_securityonion (1.2.21)

Automates Security Onion **lab** installs on Ludus and keeps the SOC grid healthy afterward.

Official SO does not support unattended installs. This role uses the internal CI `TESTING=true` / `test_profile` path (`so-setup iso <type>-net`, default **standalone-net**), then heals the post-setup failure modes that leave Zeek dark, Elasticsearch dead, or the grid on **Fault**.

Works with plain Ludus CLI/API deploy. No LUX required (LUX may also attach sniff `net1`; that is idempotent).

## Why this role exists

Ludus clones VMs with a single NIC. Security Onion standalone needs:

1. A **management** NIC (already present)
2. A **sniff** NIC on the target VLAN with no IP (Ludus never adds this)
3. The range bridge in **hub mode** (`bridge-ageing 0`) so the sniff NIC sees all VLAN frames
4. A completed `so-setup`, then sensors bound to `bond0`
5. A Fleet Server policy named `FleetServer_<hostname>` before `so-boot-highstate` waits on `:8220`

Without those steps, deploy “succeeds” while NSM is empty and SOC shows Fault. Redeploys also hit dirty `/nsm` XFS, missing containers, and Kibana HTTP 503 while Fleet is already usable — this role heals those too.

## Requirements

- VM from `securityonion-2.4-x64-template`, `securityonion-3-x64-template`, or `securityonion-3.3-x64-template`
- Role run during **Ludus range deploy** (Ludus injects `PROXMOX_*` into ansible-playbook)
- Ludus extra vars: `range_second_octet`, `vm_target_nodes`, `inventory_hostname`
- Internet on the SO management VLAN for Standard install pulls (unless airgap images are present)
- **Testing Mode off** (or SO repo hosts allowlisted) — see [DNS](#dns-and-internet-common-setup-failure)

## Ludus-provided inputs

| Source | Used for |
|---|---|
| `PROXMOX_URL`, `PROXMOX_USERNAME`, `PROXMOX_TOKEN`, `PROXMOX_SECRET` | Proxmox API auth |
| `range_second_octet` / `LUDUS_RANGE_NUMBER` | Range bridge / SDN vnet selection |
| `vm_target_nodes` / `PROXMOX_NODE` | Proxmox node lookup |
| `inventory_hostname` | VM name in Proxmox |

Controller helpers that write under `delegate_to: localhost` use `files/controller-remote-tmp.sh` because the Ludus service has `ProtectHome=read-only` and role files are mode `644` (bash wrapper, not a direct exec).

## What it does (task flow)

### First install (no setup marker)

1. **Version assert** — optional `ludus_so_expect_version` (e.g. `3.3`)
2. **Attach sniff NIC** — Proxmox API `net1` on the sniff bridge/tag (SDN `rN` or classic `vmbr10XX`)
3. **Wait for guest NICs** — mgmt + sniff appear under `/sys/class/net`
4. **Sanitize sniff** — strip DHCP/default route on sniff so Ansible SSH does not break
5. **DNS preflight** — Ludus router must resolve `repo.securityonion.net`
6. **Prepare networking / memory** — pick MNIC/BNIC, ensure ≥16 GiB MemTotal for standalone
7. **Sanitize docker daemon.json** — remove broken `registry-mirrors` before image pulls
8. **Patch so-setup** — TESTING profile must not treat `bonding_masters` as MNIC; Fleet grid retry
9. **Run `so-setup`** — `TESTING=true`, `MTU=1500`, open analyst CIDR `0.0.0.0/0` (router enforces access)
10. **Write** `/etc/ludus-so-setup-complete`

### Always (fresh or redeploy)

1. Open analyst firewall hostgroup
2. **Enslave sniff → `bond0`** (+ `ludus-so-enslave-sniff.service` for boot)
3. **Reboot if needed** — so-soc reboot pill / `needs-restarting` after kernel update
4. **Heal `/nsm`** — remount or `xfs_repair -L` when the volume returns I/O errors (otherwise ES gone, Kibana 503)
5. **Heal containers** — start missing/unhealthy required containers and wait
6. **Grid healthy** — ensure Fleet Server policy `FleetServer_<hostname>` (Elasticsearch output + fleet_server integration), patch Influx `manager` SAN only when missing, keep pipeline retry patches so boot highstate does not Fault the node

Helper installed on the guest: `/usr/local/sbin/ludus-so-ensure-fleet-policy` (also run from `ludus-so-fleet-policy.service` early in boot). With `--require-healthy` it waits for Fleet API readiness even when Kibana `/api/status` stays 503 for a degraded plugin.

## Role variables

| Variable | Default | Purpose |
|---|---|---|
| `ludus_so_attach_sniff_nic` | `true` | Attach `net1` via Proxmox API before waiting |
| `ludus_so_sniff_tag` | `10` | 802.1Q tag on sniff NIC (targets VLAN in SO labs) |
| `ludus_so_sniff_mtu` | `""` | Optional Proxmox `net1` MTU (empty = inherit bridge, usually 1500) |
| `ludus_so_bond_mtu` | `1500` | Monitor/bond MTU for `so-setup` (virtio labs; do not use 9000 without jumbo bridge) |
| `ludus_so_install_type` | `standalone` | `standalone` or `eval` |
| `ludus_so_expect_version` | `""` | Require ISO `VERSION` prefix; empty skips |
| `ludus_so_setup_profile_suffix` | `net` | Profile suffix for so-setup |
| `ludus_so_mem_min_gb` / `ludus_so_mem_target_gb` | `16` / `20` | Standalone MemTotal floor / suggested VM RAM |
| `ludus_so_sniff_wait_timeout` | `1800` | Seconds to wait for sniff NIC in guest |
| `ludus_so_web_user` / `ludus_so_web_password` | lab defaults | SOC user for TESTING profile |
| `ludus_so_allow_cidr` | `""` | Unused; analyst group is always `0.0.0.0/0` |
| `ludus_so_require_dns` | `true` | Fail before `so-setup` if repo hosts do not resolve |
| `ludus_so_heal_sniff_bond` | `true` | Enslave sniff to `bond0` + oneshot service |
| `ludus_so_heal_nsm` | `true` | Remount / `xfs_repair -L` when `/nsm` I/O fails |
| `ludus_so_heal_containers` | `true` | Start missing/unhealthy containers |
| `ludus_so_heal_grid` | `true` | Fleet policy + Influx SAN + pipeline retry before highstate |
| `ludus_so_reboot_if_needed` | `true` | Reboot when so-soc / needs-restarting say so |
| `ludus_so_reboot_timeout` | `900` | Seconds to wait for SSH after reboot |
| `ludus_so_required_containers` | ES, Kibana, nginx, soc, suricata, zeek, fleet | Must be up before later roles |

## DNS and internet (common setup failure)

`so-setup` pulls from `repo.securityonion.net` / `repo-alt.securityonion.net` via **Ludus range router DNS**:

`10.<range_number>.<vlan>.254`

**Most common failure: Ludus Testing Mode is ON.** Testing blocks outbound internet/DNS — stop testing before `so-setup`, or allowlist those hosts. If the SO VM has a `testing:` block, set `block_internet: true` (Ludus requires the key); never use `false` to bypass isolation for setup.

```bash
ping -c1 10.1.20.254
dig @10.1.20.254 repo.securityonion.net
getent hosts repo.securityonion.net
```

## Notes

- Ludus range bridges use **MTU 1500**; `mtu=9000` on `net1` fails on virtio. The role passes `MTU=1500` into `so-setup`.
- A failed install can leave `bond0` behind; prepare tasks remove it so TESTING picks mgmt (`ens18`) not `bond0`.
- Hub mode prefers a local/sysfs write, then `sudo -n lux-host bridge-ageing`, then root SSH. Classic `vmbr` bridges can also use the Proxmox network API with a keep-taps option. SDN `rN` vnets never go through that API reload (it drops live taps).
- Zeek/Suricata listen on **`bond0`**. If sniff is not enslaved, `bond0` is NO-CARRIER and NSM is empty.
- Fleet Server policies created here pin the **Elasticsearch** output. When the grid default is `so-manager_logstash`, an unpinned create inherits Logstash and Kibana rejects Fleet Server policies.
- Marker: `/etc/ludus-so-setup-complete` (also accepts `/opt/so/state/setup-complete` and backfills the Ludus marker for downstream roles).

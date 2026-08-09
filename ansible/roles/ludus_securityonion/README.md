# ludus_securityonion

Attaches a sniff `net1` on Proxmox during Ludus deploy (Proxmox API via same env vars
as `range-management/proxmox.py`), waits for the guest to see it, then runs
Security Onion `so-setup iso <type>-net` (default **standalone-net**).

Works with plain Ludus CLI/API deploy. No LUX required.

## Automated testing (catshadowstep)

End-to-end role test without watching logs manually:

```bash
# From ludus-source-meow repo (needs SSH to Ludus host; key from ludus-ux container or LUDUS_SSH_KEY)
./scripts/test-role-deploy.sh full

# Or via the template test runner
./scripts/run-automated-tests.sh role-deploy
```

Defaults: range `catshadowstep`, VM `catshadowstep-so`, role `ryokubaka.ludus_securityonion`,
deploy `--limit` + `--tags user-defined-roles` + `--only-roles`. Cleans stale `bond0`/marker,
monitors `/opt/ludus/ranges/catshadowstep/ansible.log` (timeout 2h), verifies
`/etc/ludus-so-setup-complete` and `so-status`.

Useful env overrides: `SO_VM_IP=10.1.10.20`, `CLEANUP_BEFORE=0`, `SKIP_SOURCE_SYNC=1`,
`DEPLOY_TIMEOUT_SEC=7200`.

Modes: `full` | `deploy` | `monitor` | `verify`.

## Requirements

- VM built from `securityonion-2.4-x64-template` or `securityonion-3-x64-template`
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
| `ludus_so_setup_profile_suffix` | `net` | Profile suffix for so-setup |
| `ludus_so_sniff_wait_timeout` | `1800` | Seconds to wait for sniff NIC in guest |
| `ludus_so_web_user` | `onionadmin@ludus.local` | SOC user (TESTING profile) |
| `ludus_so_web_password` | `0n10nAdm1n!` | SOC password |
| `ludus_so_allow_cidr` | `""` | Firewall allow CIDR (empty → open in TESTING) |
| `ludus_so_require_dns` | `true` | Fail before `so-setup` if SO repo hostnames do not resolve |
| `ludus_so_range_number_override` | `""` | Rare fallback if range number extra var missing |
| `ludus_so_heal_sniff_bond` | `true` | Enslave sniff NIC to `bond0` + systemd oneshot (sensors listen on bond0) |

## DNS and internet (common setup failure)

`so-setup` pulls packages from `repo.securityonion.net` / `repo-alt.securityonion.net`.
The SO VM must resolve those via **Ludus range router DNS**:

`10.<range_number>.<vlan>.254` (example: vlan 10 → `10.1.10.254`, vlan 20 → `10.1.20.254`)

**Most common failure: Ludus Testing Mode is ON.** Testing blocks outbound DNS on the
range router unless domains are allowlisted — `ping google.com` fails even when
`resolv.conf` points at `10.1.10.254`.

In `range-config.yml` for the SO VM:

```yaml
testing:
  block_internet: false   # required on the SO VM
```

**Fix order:**

1. **Stop Testing Mode** on the range (LUX → Testing, or Ludus `testing/stop`).
2. If testing must stay on, allowlist `repo.securityonion.net` and `repo-alt.securityonion.net`.
3. Ensure `block_internet: false` on the SO VM; redeploy after `ludus source update meow`.

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
Bridge `ageing_time 0` is attempted on the Ludus host when it can reach the range bridge
(non-fatal if not).

After `so-setup`, zeek/suricata listen on **`bond0`**. If the sniff NIC (`ens19`) is not
enslaved, `bond0` stays NO-CARRIER and NSM sees no range traffic. This role runs
`ensure-sniff-bond.yml` after setup and on redeploy (marker present) to enslave the
sniff NIC and install `ludus-so-enslave-sniff.service` for boot persistence.

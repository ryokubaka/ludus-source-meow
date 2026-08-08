# ludus_securityonion

Attaches a sniff `net1` on Proxmox during Ludus deploy (Proxmox API via same env vars
as `range-management/proxmox.py`), waits for the guest to see it, then runs
Security Onion `so-setup iso <type>-net` (default **standalone-net**).

Works with plain Ludus CLI/API deploy. No LUX required.

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
| `ludus_so_install_type` | `standalone` | `standalone` or `eval` |
| `ludus_so_setup_profile_suffix` | `net` | Profile suffix for so-setup |
| `ludus_so_sniff_wait_timeout` | `1800` | Seconds to wait for sniff NIC in guest |
| `ludus_so_web_user` | `onionadmin@ludus.local` | SOC user (TESTING profile) |
| `ludus_so_web_password` | `0n10nAdm1n!` | SOC password |
| `ludus_so_allow_cidr` | `""` | Firewall allow CIDR (empty → open in TESTING) |
| `ludus_so_range_number_override` | `""` | Rare fallback if range number extra var missing |

## Notes

Official Security Onion does not support automated installs; this role uses the
internal CI `test_profile` path (`TESTING=true`) for lab automation only.

Ludus attaches only **one** NIC per VM at clone time; this role adds the second
(sniff) NIC via Proxmox API before `so-setup`. Bridge `ageing_time 0` is attempted
on the Ludus host when it can reach the range bridge (non-fatal if not).

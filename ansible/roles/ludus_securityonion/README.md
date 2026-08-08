# ludus_securityonion

Attaches a sniff `net1` on Proxmox during Ludus deploy, waits for the guest to
see it, then runs Security Onion `so-setup iso <type>-net` (default **standalone-net**).

Works with plain Ludus (CLI or API). LUX sniff workflow is optional — idempotent if both run.

## Requirements

- VM built from `securityonion-2.4-x64-template` or `securityonion-3-x64-template`
- Role run during **Ludus range deploy** (Proxmox API token env vars on localhost)
- Internet on the SO management VLAN for Standard install pulls (unless airgap images present)
- For packet capture: bridge `ageing_time 0` on the range `vmbr` (role tries local/SSH; see Ludus [packet capture](https://docs.ludus.cloud/docs/networking#packet-capture))

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
| `ludus_so_proxmox_ssh_host` | `""` | Proxmox SSH for bridge-ageing when Ludus ≠ hypervisor |

## Notes

Official Security Onion does not support automated installs; this role uses the
internal CI `test_profile` path (`TESTING=true`) for lab automation only.

Ludus attaches only **one** NIC per VM at clone time; this role adds the second
(sniff) NIC via Proxmox API before `so-setup`.

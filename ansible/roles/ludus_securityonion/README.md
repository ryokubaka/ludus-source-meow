# ludus_securityonion

Waits for a second (sniff) NIC — attached by LUX during Ludus deploy — then runs
Security Onion `so-setup iso <type>-net` (default **standalone-net**).

## Requirements

- VM built from `securityonion-2.4-x64-template` or `securityonion-3-x64-template`
- LUX so-sniff workflow enabled (hub-mode bridge + `net1`)
- Internet on the SO management VLAN for Standard install pulls (unless airgap images present)

## Role variables

| Variable | Default | Purpose |
|---|---|---|
| `ludus_so_install_type` | `standalone` | `standalone` or `eval` |
| `ludus_so_setup_profile_suffix` | `net` | Profile suffix for so-setup |
| `ludus_so_sniff_wait_timeout` | `1800` | Seconds to wait for sniff NIC |
| `ludus_so_web_user` | `onionadmin@ludus.local` | SOC user (TESTING profile) |
| `ludus_so_web_password` | `0n10nAdm1n!` | SOC password |
| `ludus_so_allow_cidr` | `""` | Firewall allow CIDR (empty → open in TESTING) |

## Notes

Official Security Onion does not support automated installs; this role uses the
internal CI `test_profile` path (`TESTING=true`) for lab automation only.

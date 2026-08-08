# Ludus Templates

| Template | Description |
|---|---|
| `securityonion-2.4-x64-template` | SO 2.4.211 base. `so-setup` at range deploy. |
| `securityonion-3-x64-template` | SO 3.2.0 base. `so-setup` at range deploy. |

## Ludus template compliance

Follows [Ludus template guidance](https://docs.ludus.cloud/docs/using-ludus/templates) and [ludus-source-bsl](https://github.com/badsectorlabs/ludus-source-bsl) layout:

- Required Ludus packer variables (`proxmox_*`, `ansible_home`, `ludus_nat_interface`, …)
- Performance: `cpu_type=host`, `virtio-scsi-single`, `discard`, `io_thread`, virtio NIC on `ludus_nat_interface`
- Linux template requirements: qemu-guest-agent, SSH, python3, sudo, DHCP
- Ansible playbooks (BSL order): `ludus-linux-prereqs.yml` → `securityonion-prep.yml` → `reset-machine-id.yml` → `reset-ssh-host-keys.yml`
- Credentials: `onion:onion` (SO default; exception to `localuser:password` convention)

**SO-specific:** stock ISO has no guest-agent during install ([proxmox#91](https://github.com/hashicorp/packer-plugin-proxmox/issues/91)), so packer uses `communicator=none` + shell-local DHCP SSH scan instead of BSL's `communicator=ssh` + packer ansible provisioner. Same playbooks and ansible env vars as BSL.

## Security Onion Packer path

1. Stock ISO: `yes` / `onion`×3 / Enter (~10m) / reboot.
2. Login → **Cancel so-setup** (autostarts; blocks shell/DHCP).
3. Strip so-setup from profiles; `nmcli`/`dhclient` + sshd.
4. shell-local SSH-scans Ludus DHCP **`192.0.2.50–100`**.
5. Ansible hardens per Ludus Linux template requirements. `so-setup` runs at range deploy only.

Sync to `/opt/ludus/packer/securityonion-2.4/`. Log must show `H35-ludus-template-align-20260808`, then four ansible playbooks completing.

```bash
ludus templates build -n securityonion-2.4-x64-template
```

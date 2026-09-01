# Ludus Templates

Dummy-friendly walkthrough (ISO → golden VM → range clone, plus “build destroyed the VM”): [docs/templates-for-dummies.md](../docs/templates-for-dummies.md).

| Template | Description |
|---|---|
| `securityonion-2.4-x64-template` | SO **2.4.211** (`securityonion-2.4.211-20260407.iso`). `so-setup` at range deploy. |
| `securityonion-3-x64-template` | SO **3.2.0** (`securityonion-3.2.0-20260729.iso`). `so-setup` at range deploy. |

## Ludus template compliance

Follows [Ludus template guidance](https://docs.ludus.cloud/docs/using-ludus/templates) and [ludus-source-bsl](https://github.com/badsectorlabs/ludus-source-bsl) layout:

- Required Ludus packer variables (`proxmox_*`, `ansible_home`, `ludus_nat_interface`, …)
- Performance: `cpu_type=host`, `virtio-scsi-single`, `discard`, `io_thread`, virtio NIC on `ludus_nat_interface`
- Linux template requirements: qemu-guest-agent, SSH, python3, sudo, DHCP
- Ansible playbooks (BSL order): `ludus-linux-prereqs.yml` → `securityonion-prep.yml` → `reset-machine-id.yml` → `reset-ssh-host-keys.yml`
- Credentials: `onion:onion` (SO default; exception to `localuser:password` convention)
- **Oracle Linux inventory:** Ludus maps SO to ansible group `ol`. Install `ansible/group_vars/ol.yml` on the Ludus host once:

```bash
LUDUS_HOST=your.ludus.host ./scripts/install-ol-group-vars.sh
# optional: LUDUS_SSH_KEY=/path/to/key
```

**SO-specific:** stock ISO has no guest-agent during install ([proxmox#91](https://github.com/hashicorp/packer-plugin-proxmox/issues/91)), so packer uses `communicator=none` + shell-local DHCP SSH scan instead of BSL's `communicator=ssh` + packer ansible provisioner. Same playbooks and ansible env vars as BSL.

## Security Onion Packer path

1. Stock ISO: `yes` / `onion`×3 / Enter (~10m) / reboot.
2. Login → **Cancel so-setup** (autostarts; blocks shell/DHCP).
3. Strip so-setup from profiles; wipe cancelled `sosetup.log`/`installtmp`; `nmcli`/`dhclient` + sshd.
4. shell-local SSH-scans Ludus DHCP **`192.0.2.50–100`**.
5. Ansible hardens per Ludus Linux template requirements. `so-setup` runs at range deploy only.

After installing from this source, Packer content lives under `/opt/ludus/packer/securityonion-2.4/` (or `securityonion-3/`). Provision logs print `SCRIPT_VERSION=1.0.0` from `packer-provision-via-dhcp.sh`.

**Shared storage note:** If Ludus `ludus` storage is CIFS/NFS, heavy concurrent VM disk I/O during packer can cause storage lock timeouts. Pause busy range VMs for the build if that happens, then resume after.

```bash
ludus templates build -n securityonion-2.4-x64-template
ludus templates build -n securityonion-3-x64-template
```

Packer invokes `scripts/packer-provision-via-dhcp.sh` via `bash`; git marks those scripts `+x`. Shell-local permission failures: [docs/templates-for-dummies.md](../docs/templates-for-dummies.md). SO script paths on an older checkout, or if you copied files without mode bits:

```bash
chmod +x templates/securityonion-2.4/scripts/*.sh templates/securityonion-3/scripts/*.sh
# already installed on a Ludus host:
# chmod +x /opt/ludus/packer/securityonion-2.4/scripts/*.sh
# chmod +x /opt/ludus/packer/securityonion-3/scripts/*.sh
```

## Unit tests

Validates liburing + guest-agent RPM pairing logic (no Ludus host required):

```bash
cd templates/securityonion-2.4
bash tests/test-qemu-ga-logic.sh

cd templates/securityonion-3
bash tests/test-qemu-ga-logic.sh
```

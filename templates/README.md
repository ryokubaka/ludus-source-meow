# Ludus Templates

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
- **Oracle Linux inventory:** Ludus maps SO to ansible group `ol`. Install `ansible/group_vars/ol.yml` on the Ludus host once: `./scripts/install-ol-group-vars.sh`

**SO-specific:** stock ISO has no guest-agent during install ([proxmox#91](https://github.com/hashicorp/packer-plugin-proxmox/issues/91)), so packer uses `communicator=none` + shell-local DHCP SSH scan instead of BSL's `communicator=ssh` + packer ansible provisioner. Same playbooks and ansible env vars as BSL.

## Security Onion Packer path

1. Stock ISO: `yes` / `onion`×3 / Enter (~10m) / reboot.
2. Login → **Cancel so-setup** (autostarts; blocks shell/DHCP).
3. Strip so-setup from profiles; `nmcli`/`dhclient` + sshd.
4. shell-local SSH-scans Ludus DHCP **`192.0.2.50–100`**.
5. Ansible hardens per Ludus Linux template requirements. `so-setup` runs at range deploy only.

Sync to `/opt/ludus/packer/securityonion-2.4/` (or `securityonion-3/`). Log must show `H37-liburing-local-repo-20260808`.

**CIFS note:** `ludus` storage is CIFS. Active GOAD/range VMs (105/106/109) can cause `storage-ludus`-locked timeouts during packer VM create. `run-automated-tests.sh full` pauses them automatically; manual builds may need `qm stop` on those VMs first.

```bash
ludus templates build -n securityonion-2.4-x64-template
```

## Automated testing

From repo root (uses ludus-ux SSH key via Docker if needed):

```bash
./scripts/run-automated-tests.sh unit          # ~1s local
./scripts/run-automated-tests.sh sync          # rsync to Ludus /opt/ludus/packer/
./scripts/run-automated-tests.sh integration   # live VM on Ludus (~1–2 min)
./scripts/run-automated-tests.sh full          # sync + ludus templates build
```

Env: `SO_TEMPLATE=securityonion-2.4|securityonion-3`, `LUDUS_HOST=10.0.20.40`, `SO_TEST_IP=`.

## Fast testing (skip 15m packer ISO install)

### 1. Unit tests (~1s, any machine)

Validates liburing + guest-agent RPM pairing logic:

```bash
cd templates/securityonion-2.4
bash tests/test-qemu-ga-logic.sh
```

### 2. Guest-agent only on live SO VM (~30s, Ludus host)

While packer VM still up (or any `onion` SSH reachable VM):

```bash
cd /opt/ludus/packer/securityonion-2.4
SO_TEST_IP=192.0.2.65 SSH_PASS=onion ./scripts/test-provision-against-vm.sh --guest-agent-only
```

### 3. Full ansible provision only (~1–2 min, Ludus host)

Same playbooks as packer, no ISO:

```bash
cd /opt/ludus/packer/securityonion-2.4
SO_TEST_IP=192.0.2.65 \
ANSIBLE_HOME=/opt/ludus/users/catshadowstep/.ansible \
SSH_PASS=onion \
./scripts/test-provision-against-vm.sh
```

Omit `SO_TEST_IP` to auto-scan Ludus DHCP `.50–.100` (same as packer).

**Workflow:** start packer build → when VM at login/shell with SSH, run test #2 or #3 in another terminal → fix → re-test in seconds → full packer only when tests pass.

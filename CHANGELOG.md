# Changelog

All notable changes to [ludus-source-meow](https://github.com/ryokubaka/ludus-source-meow) will be documented in this file.

Each bullet uses a single tag:

- **[Add]** — New capability
- **[Fix]** — Bug or wrong behavior
- **[Improve]** — UX polish or refactor without a new feature
- **[Docs]** — Documentation improvement

---

## [1.0.0] - 2026-08-08

**Templates**
- [Add] **`securityonion-2.4-x64-template`** — Packer base for Security Onion **2.4.211** (`securityonion-2.4.211-20260407.iso`). `so-setup` runs at range deploy via `ryokubaka.ludus_securityonion`, not during template build.
- [Add] **`securityonion-3-x64-template`** — Packer base for Security Onion **3.2.0** (`securityonion-3.2.0-20260729.iso`).
- [Add] **SO-specific Packer path** — Stock ISO has no guest-agent during install ([proxmox#91](https://github.com/hashicorp/packer-plugin-proxmox/issues/91)), so templates use `communicator=none` + shell-local DHCP SSH scan (`192.0.2.50–100`) instead of BSL's `communicator=ssh` + packer ansible provisioner. Same ansible playbooks and env as [ludus-source-bsl](https://github.com/badsectorlabs/ludus-source-bsl).
- [Add] **Guest-agent provisioning** — Install `liburing` + `qemu-guest-agent` from ISO-local `/nsm/repo` (Oracle OL9 fallback); `qemu_agent=true` for Proxmox virtio channel; `install-qemu-guest-agent.sh` + ansible playbooks.
- [Add] **Automated testing** — `scripts/run-automated-tests.sh` (`unit` / `sync` / `integration` / `full`); unit tests in `tests/test-qemu-ga-logic.sh`; fast re-provision via per-template `scripts/test-provision-against-vm.sh` (~30s–2min on live VM, no ISO).
- [Add] **Templates README** — Version pins, testing tiers, CIFS note (pause GOAD VMs 105/106/109 during builds when `storage-ludus` lock timeouts occur).

**Blueprints**
- [Add] **`securityonion-lab`** — SO 2.4 standalone + target + Kali; `requirements.yml` + `range-config.yml` use `ryokubaka.ludus_securityonion`.
- [Add] **`securityonion3-lab`** — SO 3.2.0 standalone + target + Kali.

**Ansible**
- [Add] **`ludus_securityonion` role** — Attach sniff `net1` via Proxmox API during Ludus deploy; wait for guest NIC; run `so-setup iso standalone-net`. No LUX required.
- [Fix] **`ludus_securityonion` sniff MTU** — Do not force Proxmox `net1` `mtu=9000` (Ludus `vmbr` is 1500; guest virtio cannot exceed bridge). Pass `MTU=1500` to `so-setup`; strip erroneous jumbo MTU from existing `net1`.
- [Add] **`ludus_securityonion` DNS preflight** — Fail before `so-setup` when SO repo hostnames do not resolve; documents `block_internet: false` and Ludus testing-mode DNS requirements.
- [Add] **`ludus_securityonion` Ludus DNS setup** — Pin NM DNS to vlan `.254` and probe router forwarder with `dig` before `so-setup`.

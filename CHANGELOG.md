# Changelog

All notable changes to [ludus-source-meow](https://github.com/ryokubaka/ludus-source-meow) will be documented in this file.

Each bullet uses a single tag:

- **[Add]** — New capability
- **[Improve]** — UX polish or refactor without a new feature
- **[Docs]** — Documentation improvement

---

## [1.0.0] - 2026-08-09

**Templates**
- [Add] **`securityonion-2.4-x64-template`** — Packer base for Security Onion **2.4.211** (`securityonion-2.4.211-20260407.iso`). `so-setup` runs at range deploy via `ryokubaka.ludus_securityonion`, not during template build.
- [Add] **`securityonion-3-x64-template`** — Packer base for Security Onion **3.2.0** (`securityonion-3.2.0-20260729.iso`).
- [Add] **SO-specific Packer path** — Stock ISO has no guest-agent during install ([proxmox#91](https://github.com/hashicorp/packer-plugin-proxmox/issues/91)), so templates use `communicator=none` + shell-local DHCP SSH scan (`192.0.2.50–100`) instead of BSL's `communicator=ssh` + packer ansible provisioner. Same ansible playbooks and env as [ludus-source-bsl](https://github.com/badsectorlabs/ludus-source-bsl). Pause GOAD VMs for the whole packer/clone on CIFS (`storage-ludus` lock timeouts if resumed early).
- [Add] **Guest-agent provisioning** — Install `liburing` + `qemu-guest-agent` from ISO-local `/nsm/repo` (Oracle OL9 fallback); `qemu_agent=true` for Proxmox virtio channel; `install-qemu-guest-agent.sh` + ansible playbooks.
- [Add] **Automated testing** — `scripts/run-automated-tests.sh` (`unit` / `sync` / `integration` / `full`); unit tests in `tests/test-qemu-ga-logic.sh`; fast re-provision via per-template `scripts/test-provision-against-vm.sh` (~30s–2min on live VM, no ISO).
- [Docs] **Templates README** — Version pins, testing tiers, CIFS note (pause GOAD VMs 105/106/109 during builds).

**Blueprints**
- [Add] **`securityonion-lab`** — SO 2.4 standalone + target + Kali; `ram_min_gb: 8` + `ram_gb: 24`; `requirements.yml` + `range-config.yml` use `ryokubaka.ludus_securityonion`.
- [Add] **`securityonion3-lab`** — SO 3.2.0 standalone + target + Kali; `ram_min_gb: 24` + `ram_gb: 24` (so-setup needs ≥16 GiB guest RAM — no balloon under floor).

**Ansible**
- [Add] **`ludus_securityonion` role** — Attach sniff `net1` via Proxmox API during Ludus deploy (bridge MTU 1500, no jumbo); wait for guest NIC with PCI rescan / udev settle; run `so-setup iso standalone-net`. No LUX required. Shared by SO 2.4 + 3.2.
- [Add] **`ludus_securityonion` sniff bond heal** — After setup (and on redeploy), enslave BNICS to `bond0`, persist via `ludus-so-enslave-sniff.service`, re-assert range bridge `ageing_time=0`. Sensors listen on `bond0`; without slaves zeek/suricata see zero traffic.
- [Add] **`ludus_so_elastic_agent` role** — Enroll Linux/Windows endpoints into SO Fleet (`endpoints-initial`). Opens `elastic_agent_endpoint` hostgroup, fetches enrollment token, copies SO-bundled installers from manager. Blueprints wire role on target/kali with `depends_on` SO + inter-VLAN Fleet ports `8220/5055/8443`.
- [Add] **`ludus_securityonion` DNS** — Preflight SO repo hostnames; pin NM DNS / `global-dns` to vlan `.254`; `ludus-dns-keeper` + dispatcher re-pin while `so-setup` rewrites networking/bond; pass `MDNS` into setup env.
- [Add] **`ludus_securityonion` TESTING MNIC** — Patch guest `so-setup` so TESTING respects env `MNIC`/`BNICS`/`ALLOW_CIDR`/web creds; exclude `bonding_masters`; prefer iface holding `ansible_host`; sanitize sniff DHCP. Regex fallback for SO 3.x nic_list block.
- [Add] **`ludus_securityonion` docker daemon sanitize** — Strip broken `registry-mirrors` (`https://:5000`) + allow insecure `manager:5000` before image pulls.
- [Add] **`ludus_securityonion` setup wait** — Abort only on terminal patterns (`unrecoverable failure`, `Command continues to fail`, `unknown connection`); ignore transient Curl/dnf `Error:` and bare `giving up.`; prefer live `so-status` after exit; scan `/root/sosetup.log`.
- [Add] **Automated role deploy test** — `scripts/test-role-deploy.sh` syncs source, installs role, cleans stale SO state (salt stop + PKI wipe), deploys `--only-roles`, monitors ansible.log + guest sosetup (last PLAY RECAP only), verifies marker + `so-status`. Also `./scripts/run-automated-tests.sh role-deploy`.

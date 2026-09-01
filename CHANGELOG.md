# Changelog

All notable changes to [ludus-source-meow](https://github.com/ryokubaka/ludus-source-meow) will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each bullet uses a single tag:

- **[Add]** — New capability
- **[Improve]** — UX polish or refactor without a new feature
- **[Fix]** — Bug fix
- **[Docs]** — Documentation improvement

Write new notes under **[Unreleased]**. After merge to `main`, CI promotes that
section to the next GitHub Release (patch by default). Put
`<!-- release: minor -->` or `<!-- release: major -->` in Unreleased when the
bump is not a patch. Do not invent a version heading on a feature branch.

---

## [Unreleased]

- [Add] **Changelog release CI** — On `main`, promote `[Unreleased]` to the next semver, tag `vX.Y.Z`, and publish a GitHub Release (`scripts/release.mjs`). PRs run release-script tests and `bash -n` on shipped `.sh` files.

## [1.1.2] - 2026-09-02

**Templates**
- [Fix] **Packer provision scripts** — Git stored `.sh` as `0644`; Packer `shell-local` exec'd the file and failed, then destroyed the VM. Invoke via `bash {{.Script}}` and mark provision scripts `+x` in git.

**Docs**
- [Docs] **Templates for dummies** — `docs/` walkthrough of ISO → Packer → Proxmox template → range clone, plus the common bake failures.

## [1.1.1] - 2026-08-09

**Ansible**
- [Fix] **`ludus_securityonion` so-setup wait** — Truncate stale `/root/sosetup.log` before start (template TTY cancel leaves `"Setup completed"` + `"User cancelled"`). Require `so-status`/`so-firewall`+`/opt/so` for success; treat User cancelled as failure. Role `1.0.2`.
- [Fix] **`ludus_so_elastic_agent`** — After marker, verify `so-firewall` exists on manager (blocks false-complete markers). Role `1.0.2`.
- [Fix] **Sniff NIC DHCP before DNS** — Sanitize sniff iface immediately after hot-plug (before DNS/copy tasks) so ansible SSH does not die on dual default routes.

**Templates**
- [Fix] **SO Packer prep** — Wipe cancelled `sosetup.log` / `installtmp` leftovers so clones do not carry false "Setup completed" breadcrumbs (2.4 + 3).

## [1.1.0] - 2026-08-09

**Blueprints**
- [Add] **`securityonion-lab` / `securityonion3-lab` AD targets** — Replace Debian target with Win2019 DC (`meow.local` primary-dc) + domain-joined Win11; Fleet agent on both Windows hosts. Version `1.1.0`.
- [Add] **Adaptix C2 on Kali** — `badsectorlabs.ludus_adaptix_c2` (server + client) on the attacker box; WireGuard → `:4321`. No elastic agent on Kali.
- [Fix] **Agent `depends_on` placement** — Nest `depends_on` under the role object (Ludus ignores VM-level `depends_on`); SO role runs before Fleet agents when adding SO to an existing range.
- [Docs] SO lab READMEs — updated topology, templates, Adaptix credentials.

**Ansible**
- [Improve] **`ludus_so_elastic_agent`** — Wait up to 10m for `/etc/ludus-so-setup-complete`; fail with role-level `depends_on` example if missing.

## [1.0.0] - 2026-08-09

**Templates**
- [Add] **`securityonion-2.4-x64-template`** — Packer base for Security Onion **2.4.211** (`securityonion-2.4.211-20260407.iso`). `so-setup` runs at range deploy via `ryokubaka.ludus_securityonion`, not during template build.
- [Add] **`securityonion-3-x64-template`** — Packer base for Security Onion **3.2.0** (`securityonion-3.2.0-20260729.iso`).
- [Add] **SO-specific Packer path** — Stock ISO has no guest-agent during install ([proxmox#91](https://github.com/hashicorp/packer-plugin-proxmox/issues/91)), so templates use `communicator=none` + shell-local DHCP SSH scan (`192.0.2.50–100`) instead of BSL's `communicator=ssh` + packer ansible provisioner. Same ansible playbooks and env as [ludus-source-bsl](https://github.com/badsectorlabs/ludus-source-bsl).
- [Add] **Guest-agent provisioning** — Install `liburing` + `qemu-guest-agent` from ISO-local `/nsm/repo` (Oracle OL9 fallback); `qemu_agent=true` for Proxmox virtio channel; `install-qemu-guest-agent.sh` + ansible playbooks.
- [Docs] **Templates README** — Version pins, OL `group_vars` install helper, shared-storage note for contended CIFS/NFS builds.

**Blueprints**
- [Add] **`securityonion-lab`** — SO 2.4 standalone + target + Kali; `ram_min_gb: 8` + `ram_gb: 24`; `requirements.yml` + `range-config.yml` use `ryokubaka.ludus_securityonion`. Version `1.0.0`.
- [Add] **`securityonion3-lab`** — SO 3.2.0 standalone + target + Kali; `ram_min_gb: 24` + `ram_gb: 24` (so-setup needs ≥16 GiB guest RAM — no balloon under floor). Version `1.0.0`.
- [Add] **`starter-lab`** — Minimal Kali + Debian skeleton. Version `1.0.0`.

**Ansible**
- [Add] **Role display version `1.0.0`** — `meta/version.yml` + `galaxy_info.version` on `ludus_securityonion`, `ludus_so_elastic_agent`, `ludus_so_elastic_security` (Ludus catalog / `ludus ansible` list).
- [Add] **`ludus_securityonion` role** — Attach sniff `net1` via Proxmox API during Ludus deploy (bridge MTU 1500, no jumbo); wait for guest NIC with PCI rescan / udev settle; run `so-setup iso standalone-net`. No LUX required. Shared by SO 2.4 + 3.2.
- [Add] **`ludus_securityonion` sniff bond heal** — After setup (and on redeploy), enslave BNICS to `bond0`, persist via `ludus-so-enslave-sniff.service`, re-assert range bridge `ageing_time=0`. Sensors listen on `bond0`; without slaves zeek/suricata see zero traffic.
- [Add] **`ludus_so_elastic_agent` role** — Enroll Linux/Windows endpoints into SO Fleet (`endpoints-initial`). Opens `elastic_agent_endpoint` hostgroup, fetches enrollment token, copies SO-bundled installers from manager. Maps hostname `manager` → SO IP in guest hosts (Fleet outputs use `manager`). Blueprints wire role on target/kali with `depends_on` SO + inter-VLAN Fleet ports `8220/5055/8443`.
- [Add] **`ludus_so_elastic_security` role** — On SO manager: start Elastic trial license; set Elastic Defend (`endpoints-initial`) to `EDRComplete` with malware/ransomware/memory/behavior in **detect** mode; install/enable all prepackaged Elastic Security detection rules (GOAD-mod `extensions/elk` parity). Rules appear in Kibana (`/kibana/app/security/rules`), not SOC Detections. Apply after `ludus_securityonion`.
- [Add] **`ludus_securityonion` DNS** — Preflight SO repo hostnames; pin NM DNS / `global-dns` to vlan `.254`; `ludus-dns-keeper` + dispatcher re-pin while `so-setup` rewrites networking/bond; pass `MDNS` into setup env.
- [Add] **`ludus_securityonion` TESTING MNIC** — Patch guest `so-setup` so TESTING respects env `MNIC`/`BNICS`/`ALLOW_CIDR`/web creds; exclude `bonding_masters`; prefer iface holding `ansible_host`; sanitize sniff DHCP. Regex fallback for SO 3.x nic_list block.
- [Add] **`ludus_securityonion` docker daemon sanitize** — Strip broken `registry-mirrors` (`https://:5000`) + allow insecure `manager:5000` before image pulls.
- [Add] **`ludus_securityonion` setup wait** — Abort only on terminal patterns (`unrecoverable failure`, `Command continues to fail`, `unknown connection`); ignore transient Curl/dnf `Error:` and bare `giving up.`; prefer live `so-status` after exit; scan `/root/sosetup.log`.

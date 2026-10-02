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

## [1.2.7] - 2026-10-02

- [Fix] **`ludus_securityonion` 1.2.2** — The hub-mode script is Unix line endings. `1.2.1` was checked in with CRLF, so the Proxmox host tried to execute `python3\r` and the task died before it could set bridge ageing.

## [1.2.6] - 2026-10-02

- [Fix] **`ludus_securityonion` 1.2.1** — Set range-bridge hub mode (`ageing_time 0`) through the Proxmox root API console. The old task sudo'd on the controller, failed with "a password is required", and ignored the error, so a sniff NIC on the target VLAN still missed host-to-host traffic.

## [1.2.5] - 2026-10-02

- [Fix] **`ludus_so_elastic_security` 1.0.8** — Grant the SOC account (`onionadmin@ludus.local`) the SOC `superuser` role and every Kibana privilege. Elastic 9.4 shows "Privileges required" on the Security dashboards when the account only has the stock analyst/`feature_siem.read` set.

## [1.2.4] - 2026-10-02

- [Fix] **`ludus_securityonion` 1.2.0** — Write `/etc/ludus-so-setup-complete` when `/opt/so/state/setup-complete` already exists. Later roles only accept the Ludus marker, so an already-installed guest failed `ludus_so_elastic_security` with a `depends_on` message even though `so-setup` had finished.

## [1.2.3] - 2026-10-02

- [Fix] **`ludus_securityonion` 1.1.10** — Controller tasks (`delegate_to: localhost`) write module files under `~/.goad/ansible-remote`. `~/.ansible/tmp` is owned by the Ludus service account, so the range user cannot create a directory there and the Proxmox API call was unreachable. `ludus_so_elastic_agent` 1.0.8 and `ludus_sysmon` 1.0.2 use the same directory.

## [1.2.2] - 2026-10-02

- [Fix] **`ludus_securityonion` 1.1.9** — Controller tasks (`delegate_to: localhost`) use `/tmp/.ansible-ludus-so` for module files. Ansible was creating that directory as the guest user, which is not writable on the Ludus host, so the Proxmox API call was unreachable. `ludus_so_elastic_agent` 1.0.7 and `ludus_sysmon` 1.0.1 use the same directory.

## [1.2.1] - 2026-10-02

- [Fix] **`ludus_securityonion` 1.1.8** — Proxmox API tasks delegated to localhost use the local connection. GOAD pins `ansible_connection=ssh` on the guest, and Ansible was reusing that to SSH to the controller, so "List Proxmox VMs in cluster" died unreachable.

## [1.2.0] - 2026-10-01

- [Fix] **`ludus_so_elastic_security` 1.0.7** — Enable rules the way GOAD elk does: collect the disabled ids, then one bulk POST per chunk. The run that enabled 1972 rules had been rejected by the detection-engine bulk API and fell back to one HTTP call per rule. Chunk size is 1000, so a full prebuilt set is two calls.
- [Fix] **`ludus_so_elastic_security` 1.0.6** — Install prebuilt rules the way the Rules UI does: Fleet package `security_detection_engine` on `endpoints-initial`. The old prepackaged PUT never showed up as that install. Enable stays one bulk call per batch, so it does not sit on a per-rule loop with no output.
- [Fix] **`ludus_securityonion` 1.1.7** — After a reboot, poll until `so-zeek` and `so-suricata` are running (45 minutes). The old 5 minute `so-*-restart` async cap failed the deploy while the boot highstate was still creating them. `health: starting` counts as up.
- [Fix] **`ludus_securityonion` 1.1.6** — Reboot when so-soc still shows a pending reboot. so-setup installs a newer kernel and leaves `needs-restarting` set; the role now reboots, re-enslaves the sniff NIC, then heals containers.
- [Fix] **`ludus_so_elastic_security` 1.0.5** — Detection-rule enable on Elastic 9.4. `so_elastic` is a superuser, but Kibana still returns "User does not have permission to enable rules" until the `securitySolutionRules` enable/disable privilege is granted. The role grants it, and if bulk enable is still denied, enables the same rules through the alerting API.
- [Fix] **`ludus_so_elastic_security` 1.0.4** — Rule enable no longer uses `${#ids[@]}`. Ansible reads `{#` as a Jinja comment and refuses to load the task.
- [Improve] **`ludus_so_elastic_security` 1.0.3** — On `windows-endpoints`, enable the AppLocker, Packaged app, and Windows Defender winlog toggles next to Sysmon.
- [Fix] **`ludus_so_elastic_security` 1.0.2** — Rule enable on Elastic 9.4 sends `elastic-api-version: 2023-10-31` and counts only rules the bulk-action response actually enabled. The previous loop ignored a rejected bulk call, so the disabled count stayed at 1972 for all 50 batches.
- [Improve] **`ludus_so_elastic_security` 1.0.1** — SO 3.3 (Elastic 9.4.5) `endpoints-initial` already has Elastic Defend 9.4.1, Osquery Manager, System, Windows (Sysmon channel included), and Defender winlog. The role updates only `elastic-defend-endpoints`, and patches protection `.mode` on the existing 9.4 policy objects.
- [Improve] **`ludus_so_elastic_agent` 1.0.6** — Every run uninstalls the existing agent and enrolls again, so a redeploy follows the Security Onion instance that is up (same sequence as the GOAD-mod elk extension). Uses the Fleet uninstall token when Defend tamper protection has issued one.
- [Add] **`ludus_sysmon`** — Install Sysmon64 on Windows hosts. `securityonion-lab` 1.1.2 and `securityonion3-lab` 1.2.2 run it on the DC and Win11 before the Fleet agent. `windows-endpoints` already collects `Microsoft-Windows-Sysmon/Operational`.
- [Fix] **Security Onion sniff bond** — `ludus_securityonion` 1.1.5 lowers `bond0` to the sniff NIC MTU before enslaving it. so-setup leaves the bond at 9000, and a virtio NIC at 1500 makes the enslave write fail with `Invalid argument`.
- [Fix] **Security Onion wait** — `ludus_securityonion` 1.1.4 keeps the guest SSH password when the so-setup poll runs on the Ludus host. `delegate_to: localhost` was clearing `ansible_password`, so the poll used key-only SSH and retried until timeout after setup had finished.
- [Fix] **Security Onion firewall** — The analyst/SOC group is `0.0.0.0/0`. The range router enforces access. SO labs no longer pass the range `/16`.
- [Fix] **Security Onion Fleet grid** — `ludus_securityonion` 1.1.3 retries `elasticfleet.install_agent_grid` after a Salt master sign-in timeout, instead of aborting so-setup. The so-setup wait also caps each poll at 45s and does not treat Salt log text as an SSH flap.

**Templates**
- [Improve] **`securityonion-3.3-x64-template`** — Security Onion **3.3.0** (`securityonion-3.3.0-20260911.iso`, the 3.3.0 hotfix) as its own Packer template (`templates/securityonion-3.3`, `vm_name` `securityonion-3.3-x64-template`). SHA256 from upstream `DOWNLOAD_AND_VERIFY_ISO.md`. `so-setup` still runs at range deploy. `main` keeps `securityonion-3-x64-template` (3.2.0).
- [Improve] **`securityonion3-lab`** — Blueprint version `1.2.2`. SO VM RAM is `ram_min_gb: 20` and `ram_gb: 20`. A 16 GiB VM reports ~15.2 GiB MemTotal, under so-setup's 16 GiB check.
- [Fix] **`securityonion-lab`** — Blueprint version `1.1.2`. SO VM `ram_min_gb` is 20, matching `ram_gb`, for the same MemTotal gap.

**Ansible**
- [Improve] **`ludus_securityonion`** — `securityonion3-lab` sets `ludus_so_expect_version: "3.3"`. The role reads the ISO `VERSION` file and stops when the guest is not Security Onion 3.3. Role `1.1.2`.

## [1.1.5] - 2026-09-30

- [Fix] **Security Onion RAM floor** — SO labs set `ram_min_gb` and `ram_gb` both to 20 (`securityonion-lab` 1.1.1). A 16 GiB VM reports ~15.2 GiB MemTotal, under so-setup's 16 GiB check. The 3.2 lab stays at 24/24.

## [1.1.4] - 2026-09-30

- [Fix] **Security Onion deploy SSH** — Templates create `localuser` and the SO VM joins Ludus's built-in `rhel` group. Range deploy no longer needs a file under `/opt/ludus`. Rebuild the template before the next deploy.
- [Fix] **Security Onion memory** — `ludus_securityonion` 1.0.4 stops and starts the VM from Proxmox when MemTotal is under 16 GiB. A guest reboot leaves QEMU at the old RAM cap, so a 16 GiB VM still reports ~15 GiB and so-setup aborts. Applies to 2.4 and 3.2.
- [Fix] **Security Onion so-setup tree** — `ludus_securityonion` 1.0.5 links the ISO tree into the SSH user's home before `so-setup`. `so-setup` rsyncs `/home/$SUDO_USER/SecurityOnion`, and `localuser` has no copy, so Salt states never installed.

## [1.1.3] - 2026-09-01

- [Add] **Changelog release CI** — On `main`, promote `[Unreleased]` to the next semver, tag `vX.Y.Z`, and publish a GitHub Release (`scripts/release.mjs`). PRs run release-script tests and `bash -n` on shipped `.sh` files.
- [Fix] **Same-run promote** — After tagging or publishing the current version, CI continues and promotes `[Unreleased]` in the same job (do not wait for a later merge).

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

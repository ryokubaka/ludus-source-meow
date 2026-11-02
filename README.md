# Ludus Source - Meow

Custom [Ludus](https://docs.ludus.cloud) blueprints, Packer templates, and Ansible roles.
Modeled on the [Bad Sector Labs source layout](https://github.com/badsectorlabs/ludus-source-bsl).

Add the source; install the resources; then apply them to your range configurations and deployments.

## Quick Start

```bash
# Add this source to your Ludus server (interactive installer)
ludus source add https://github.com/ryokubaka/ludus-source-meow

# Or install everything non-interactively
ludus source add https://github.com/ryokubaka/ludus-source-meow --all

# Local development (upload from a directory)
ludus source add -d ./ludus-source-meow --id meow
# After edits:
ludus source update meow -d ./ludus-source-meow

# Build any Packer templates this source ships
ludus templates build

# Apply a blueprint and deploy
ludus blueprint apply ryokubaka-ludus-source-meow/securityonion3-lab
ludus range deploy
ludus range logs -f
```

See [Ludus Sources docs](https://docs.ludus.cloud/docs/using-ludus/sources) for flags (`--blueprints`, `--templates`, `--source-roles`, `--ref`, private git, etc.).

New to Packer / Ludus templates? Start with [docs/templates-for-dummies.md](./docs/templates-for-dummies.md).

## What this source is for

Meow ships a **Security Onion lab stack** for Ludus: Packer golden images, blueprints that wire AD targets + SO + Kali, and Ansible roles that make `so-setup`, Fleet enrollment, Elastic Security, Sysmon, and Adaptix C2 survive real Ludus/Proxmox quirks.

Upstream Security Onion is not meant for unattended installs. These roles automate the CI `TESTING` path for labs, then heal the failure modes that leave the SOC grid on **Fault**, agents unenrolled, or Adaptix unable to build.

## Blueprints

| Blueprint ID | Name | VMs | Description |
|---|---|---|---|
| [`starter-lab`](./blueprints/starter-lab/) | Starter Lab | 2 | Minimal Kali + Debian target — skeleton for new blueprints |
| [`securityonion-lab`](./blueprints/securityonion-lab/) | Security Onion 2.4 Lab | 4 | Standalone SO 2.4 + `meow.local` DC/Win11 + Kali Adaptix |
| [`securityonion3-lab`](./blueprints/securityonion3-lab/) | Security Onion 3 Lab | 4 | Standalone SO 3.3.0 + same topology as above |

Both SO labs use the same VLAN layout: **10** = sniffed AD targets, **20** = SO/SOC, **99** = Kali. See each blueprint README for diagrams, credentials, and RAM.

## Templates

| Template | Description |
|---|---|
| `securityonion-2.4-x64-template` | SO 2.4 Packer base — see [`templates/README.md`](./templates/README.md) |
| `securityonion-3.3-x64-template` | SO 3.3.0 Packer base |

```bash
ludus templates build -n securityonion-2.4-x64-template
ludus templates build -n securityonion-3.3-x64-template
```

Ludus clones only **one** NIC at deploy time. `ludus_securityonion` attaches sniff `net1` via the Proxmox API and puts the range bridge in hub mode so Zeek/Suricata see VLAN 10 traffic. [LUX](https://github.com/ryokubaka/ludus-ux) may also attach that NIC (idempotent). Official packet-capture notes: [Ludus networking](https://docs.ludus.cloud/docs/networking#packet-capture).

## Ansible roles (high level)

Roles are vendored under [`ansible/roles/`](./ansible/roles/). Full tables and submodule notes live in [`ansible/README.md`](./ansible/README.md). Each role folder has a deeper README (why it exists, task flow, variables, failure modes).

| Role | Version | Runs on | Why it exists |
|---|---|---|---|
| [`ludus_securityonion`](./ansible/roles/ludus_securityonion/) | 1.2.21 | SO manager | Attach sniff NIC, run `so-setup`, heal `/nsm` / containers / Fleet grid so boot highstate does not leave SOC on Fault |
| [`ludus_so_elastic_security`](./ansible/roles/ludus_so_elastic_security/) | 1.0.14 | SO manager | Trial license, Elastic Defend detect mode, prebuilt Kibana rules, SOC/Kibana admin grants + file-realm sync for Hunt |
| [`ludus_so_elastic_agent`](./ansible/roles/ludus_so_elastic_agent/) | 1.0.13 | Endpoints | Enroll Linux/Windows into SO Fleet `endpoints-initial`; Windows uses SO bootstrapper when MSI QuietExec lies and waits out async install |
| [`ludus_sysmon`](./ansible/roles/ludus_sysmon/) | 1.0.5 | Windows | Install Sysmon64 so `windows-endpoints` has the Operational channel SO already collects |
| [`ludus_adaptix_deps`](./ansible/roles/ludus_adaptix_deps/) | 1.0.2 | Kali | Qt6 Svg/Qml/private headers + git safe.directory / Extension-Kit ownership for Adaptix redeploys |
| [`ludus_adaptix_c2_fix`](./ansible/roles/ludus_adaptix_c2_fix/) | 1.0.0 | Kali | After [`badsectorlabs.ludus_adaptix_c2`](https://github.com/badsectorlabs/ludus_adaptix_c2): v1.2 YAML profile + systemd unit Go can run under |

### Recommended order on an SO lab

```text
SO manager:     ludus_securityonion → ludus_so_elastic_security
Windows hosts:  ludus_sysmon → ludus_so_elastic_agent  (role-level depends_on SO)
Kali:           ludus_adaptix_deps → badsectorlabs.ludus_adaptix_c2 → ludus_adaptix_c2_fix
```

Pin Adaptix with `ludus_adaptix_c2_version: v1.2` and `ludus_adaptix_c2_go_version: "1.25.4"` (v1.2 `go.mod` requires it). Fleet agents need **role-level** `depends_on` pointing at `ludus_securityonion` — VM-level `depends_on` is ignored by Ludus.

## Layout

```text
ludus-source-meow/
├── source.yml                 # repo-level metadata (required for a clean catalog)
├── docs/                      # dummy-friendly Packer / template notes
├── scripts/                   # changelog release (CI on main)
├── blueprints/<id>/           # blueprint.yml + range-config.yml (+ requirements.yml, README)
├── templates/<name>/          # Packer *.pkr.hcl (+ http/ or Autounattend.xml)
└── ansible/
    ├── roles/<role>/          # or submodule
    └── collections/<coll>/    # directory with galaxy.yml (or submodule)
```

## Contributing

See [docs/](./docs/) for a dummy-friendly Packer / template walkthrough.

See [CONTRIBUTING.md](./CONTRIBUTING.md) for blueprint authoring rules and range-config conventions.

See [CHANGELOG.md](./CHANGELOG.md) for release history.

## License

AGPL-3.0-or-later — See [LICENSE](./LICENSE)

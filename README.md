# Ludus Source - Meow

Custom [Ludus](https://docs.ludus.cloud) blueprints, Packer templates, and Ansible roles & collections.
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
ludus blueprint apply ryokubaka-ludus-source-meow/starter-lab
ludus range deploy
ludus range logs -f
```

See [Ludus Sources docs](https://docs.ludus.cloud/docs/using-ludus/sources) for flags (`--blueprints`, `--templates`, `--source-roles`, `--ref`, private git, etc.).

## Blueprints

| Blueprint ID | Name | VMs | Description |
|---|---|---|---|
| [`starter-lab`](./blueprints/starter-lab/) | Starter Lab | 2 | Minimal Kali + Debian target — skeleton for new blueprints |
| [`securityonion-lab`](./blueprints/securityonion-lab/) | Security Onion 2.4 Lab | 3 | Standalone SO 2.4 + target + Kali (LUX sniff) |
| [`securityonion3-lab`](./blueprints/securityonion3-lab/) | Security Onion 3 Lab | 3 | Standalone SO 3 + target + Kali (LUX sniff) |

## Templates

| Template | Description |
|---|---|
| `securityonion-2.4-x64-template` | SO 2.4.211 Packer base — see [`templates/README.md`](./templates/README.md) |
| `securityonion-3-x64-template` | SO 3.2.0 Packer base |

```bash
ludus templates build -n securityonion-2.4-x64-template
ludus templates build -n securityonion-3-x64-template
```

Security Onion labs expect **LUX** to attach the sniff NIC + hub-mode bridge during deploy (and reverse on delete). No manual Proxmox steps.

## Ansible content

| Role | Purpose |
|---|---|
| [`ludus_securityonion`](./ansible/roles/ludus_securityonion/) | Wait for sniff NIC; run `so-setup iso standalone-net` |

Roles and collections live under [`ansible/`](./ansible/). See [`ansible/README.md`](./ansible/README.md).

## Layout

```text
ludus-source-meow/
├── source.yml                 # repo-level metadata (required for a clean catalog)
├── blueprints/<id>/           # blueprint.yml + range-config.yml (+ requirements.yml, README)
├── templates/<name>/          # Packer *.pkr.hcl (+ http/ or Autounattend.xml)
└── ansible/
    ├── roles/<role>/          # or submodule
    └── collections/<coll>/    # directory with galaxy.yml (or submodule)
```

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for blueprint authoring rules and range-config conventions.

See [CHANGELOG.md](./CHANGELOG.md) for release history.

## License

AGPL-3.0-or-later — See [LICENSE](./LICENSE)

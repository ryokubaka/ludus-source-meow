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

## Templates

Packer templates live under [`templates/`](./templates/). Each subdirectory is one Ludus template.
Once installed they appear in `ludus templates list`. None ship yet — see [`templates/README.md`](./templates/README.md).

## Ansible content

Roles and collections live under [`ansible/`](./ansible/). Prefer **git submodules** pinned to tags (BSL pattern) so Ludus pulls them with `--recurse-submodules` on `source add` / `source sync`. See [`ansible/README.md`](./ansible/README.md).

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

## License

AGPL-3.0-or-later — See [LICENSE](./LICENSE)

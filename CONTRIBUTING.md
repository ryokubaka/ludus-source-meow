# Contributing

This repo is a [Ludus source](https://docs.ludus.cloud/docs/using-ludus/sources) — a versioned bundle of blueprints (and optionally templates / Ansible) that users add with `ludus source add`.

## Source Layout

```text
blueprints/
└── starter-lab/             each: blueprint.yml, range-config.yml, requirements.yml?, README.md
templates/                   Packer templates (one dir per template)
ansible/
├── roles/                   Roles (dirs or git submodules pinned to tags)
└── collections/             Collections (dirs with galaxy.yml, or submodules)
source.yml                   Source metadata
.gitmodules                  Submodule definitions (absolute upstream URLs)
```

## How to Add a Blueprint

1. Create `blueprints/<id>/` (`id`: lowercase, dashes)
2. Add required files (below)
3. Deploy end-to-end before merging
4. Document in the root `README.md` blueprints table

## Blueprint Directory Layout

```text
blueprints/my-ad-lab/
├── blueprint.yml          Required — display metadata
├── range-config.yml       Required — Ludus range configuration
├── requirements.yml       Optional — Galaxy / off-Galaxy roles & collections
└── README.md              Required — diagram, VMs, credentials, attack paths
```

## `blueprint.yml` Required Fields

```yaml
manifest_version: 1
id: my-ad-lab
name: "My AD Lab"
description: "..."
version: 0.1.0
config: range-config.yml

tags:
  - active-directory

min_ludus_version: "2.0.0"
```

## `requirements.yml` Format

Standard `ansible-galaxy` requirements. Declare every role/collection used in `range-config.yml` that is **not** vendored under this source's `ansible/`:

```yaml
roles:
  - name: badsectorlabs.ludus_adcs
    src: https://github.com/badsectorlabs/ludus_adcs
    version: main

collections:
  - name: badsectorlabs.ludus_windows_utils
    version: ">=1.1.35"
```

Vendored copies under `ansible/roles/` or `ansible/collections/` win — Ludus installs those pins and skips Galaxy for matching names.

## Range Config Rules

### Must Have

- `{{ range_id }}` prefix on every `vm_name`
- `{{ range_second_octet }}` for any IP references inside `role_vars`
- Templates from a built Ludus template list
- **No `router:` block** — Ludus provisions the router
- Deploys successfully end-to-end

### Should Have

- Theme-consistent hostnames
- Attacker VMs: `testing.snapshot: false`
- DCs: `sysprep: false`; member servers: `sysprep: true`

### Must NOT Have

- Hardcoded IPs / range IDs
- Real credentials or secrets

## Ansible Roles (vendored)

```text
ansible/roles/my_helper/
├── tasks/main.yml
├── defaults/main.yml
├── handlers/main.yml
├── meta/main.yml            # galaxy_info.description → Ludus catalog
└── meta/version.yml         # optional display version override
```

Reference by directory name under `roles:` in range configs.

Prefer git submodules with absolute URLs in `.gitmodules`, pinned to release tags:

```ini
[submodule "ansible/roles/ludus_example"]
  path = ansible/roles/ludus_example
  url = https://github.com/you/ludus_example.git
```

## Ansible Collections (vendored)

```text
ansible/collections/my_namespace.my_collection/
├── galaxy.yml               # namespace, name, version, description
├── roles/
└── plugins/
```

Identity comes from `galaxy.yml` (`namespace.name`), not the directory name.

## Packer Templates

```text
templates/my-debian-base/
├── my-debian-base.pkr.hcl   # include description + icon_path variables
├── icon.png                 # optional catalog icon
├── http/                    # Linux preseed / kickstart
└── Autounattend.xml         # Windows only
```

```hcl
variable "description" {
  type    = string
  default = "Debian 12 minimal base image."
}

variable "icon_path" {
  type    = string
  default = "icon.png"
}
```

Template catalog key = `*-template` name inside the `.pkr.hcl`.

## Local Dev Loop

```bash
ludus source add -d . --id meow --all
# edit files...
ludus source update meow -d .
ludus blueprint apply meow/starter-lab
ludus range deploy
```

When ready: push remote, `ludus source rm meow`, then `ludus source add https://github.com/ryokubaka/ludus-source-meow`.

## Blueprint README

Every blueprint README should include a Mermaid diagram (`graph TB`), VLAN subgraphs, `10.X.*` IPs, VM table, and credentials. No emoji in Mermaid node labels.

## Questions?

[Ludus documentation](https://docs.ludus.cloud) · [BSL source (reference implementation)](https://github.com/badsectorlabs/ludus-source-bsl)

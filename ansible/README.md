# Ludus Ansible Content

Roles and collections shipped by this source.

## Roles

Place each role under [`roles/`](./roles/) — either a normal directory or a **git submodule** pinned to a tag.

| Role | Purpose |
|---|---|
| [`ludus_securityonion`](./roles/ludus_securityonion/) | Attach sniff NIC via Proxmox API; run Security Onion `so-setup` (standalone-net default); heal `bond0` sniff enslavement |
| [`ludus_so_elastic_security`](./roles/ludus_so_elastic_security/) | On SO manager: Elastic trial + Elastic Defend detect-mode protections + enable all prepackaged Kibana Security rules (GOAD-mod elk parity) |
| [`ludus_so_elastic_agent`](./roles/ludus_so_elastic_agent/) | Deploy SO Elastic Agent to range endpoints (Linux/Windows) via Fleet `endpoints-initial`; maps `manager` → SO IP in hosts |

Example submodule (run from repo root):

```bash
git submodule add https://github.com/you/ludus_example.git ansible/roles/ludus_example
cd ansible/roles/ludus_example && git checkout v1.0.0
```

Then commit `.gitmodules` + the submodule pin.

## Collections

Place each collection under [`collections/`](./collections/). Root of the collection directory must contain `galaxy.yml`.

| Collection | Purpose |
|---|---|
| _(none yet)_ | Add collections here; document them in this table |

## Submodules

BSL pattern: absolute upstream URLs in `.gitmodules`. Ludus clones with `--recurse-submodules` on `source add` / `source sync`. Manual clone:

```bash
git clone --recurse-submodules https://github.com/ryokubaka/ludus-source-meow
```

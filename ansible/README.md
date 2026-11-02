# Ludus Ansible Content

Roles and collections shipped by this source. Role folders include a README with purpose, task flow, variables, and known failure modes. This page is the catalog.

## Roles

Place each role under [`roles/`](./roles/) — either a normal directory or a **git submodule** pinned to a tag.

| Role | Version | Purpose |
|---|---|---|
| [`ludus_securityonion`](./roles/ludus_securityonion/) | 1.2.20 | Attach sniff NIC via Proxmox API; run Security Onion `so-setup` (standalone-net default); heal sniff bond, `/nsm`, containers, and Fleet Server policy so `so-boot-highstate` does not leave the grid Fault |
| [`ludus_so_elastic_security`](./roles/ludus_so_elastic_security/) | 1.0.13 | On SO manager: Elastic trial, Elastic Defend detect-mode on `endpoints-initial`, install/enable Kibana prebuilt rules, grant SOC/Kibana admin (GOAD-mod elk parity). SO 3 writes `users_roles` after `so-user` because Kratos owns SOC roles |
| [`ludus_so_elastic_agent`](./roles/ludus_so_elastic_agent/) | 1.0.12 | Deploy SO Elastic Agent to range endpoints (Linux/Windows) via Fleet `endpoints-initial`; reinstalls on each run; maps `manager` → SO IP; Windows falls back to the SO bootstrapper when MSI QuietExec fails |
| [`ludus_sysmon`](./roles/ludus_sysmon/) | 1.0.5 | Install Sysmon64 on Windows hosts (SO `windows-endpoints` already collects the Sysmon channel) |
| [`ludus_adaptix_deps`](./roles/ludus_adaptix_deps/) | 1.0.2 | Install Qt6 Svg/Qml/private-dev, expose private Gui headers, and fix Extension-Kit git ownership so Adaptix v1.2 client builds and redeploys |
| [`ludus_adaptix_c2_fix`](./roles/ludus_adaptix_c2_fix/) | 1.0.0 | After `badsectorlabs.ludus_adaptix_c2` on Adaptix v1.2+: YAML teamserver profile (token TTLs + renamed extender paths) and a systemd unit without `MemoryDenyWriteExecute` |

Galaxy / third-party roles used by blueprints (declared in blueprint `requirements.yml`, not vendored here):

| Role | Purpose |
|---|---|
| [`badsectorlabs.ludus_adaptix_c2`](https://github.com/badsectorlabs/ludus_adaptix_c2) | Clone/build Adaptix client + server on Kali |

### Typical stack wiring

```yaml
# SO manager
roles:
  - name: ryokubaka.ludus_securityonion
  - name: ryokubaka.ludus_so_elastic_security

# Windows endpoint (depends_on must be under the role)
roles:
  - name: ryokubaka.ludus_sysmon
  - name: ryokubaka.ludus_so_elastic_agent
    depends_on:
      - vm_name: "{{ range_id }}-so"
        role: ryokubaka.ludus_securityonion

# Kali Adaptix
roles:
  - name: ryokubaka.ludus_adaptix_deps
  - name: badsectorlabs.ludus_adaptix_c2
  - name: ryokubaka.ludus_adaptix_c2_fix
role_vars:
  ludus_adaptix_c2_install_server: true
  ludus_adaptix_c2_install_client: true
  ludus_adaptix_c2_version: v1.2
  ludus_adaptix_c2_go_version: "1.25.4"
```

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

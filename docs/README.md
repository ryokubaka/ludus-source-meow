# Docs

Dummy-friendly notes for Ludus sources. Official product docs stay at [docs.ludus.cloud](https://docs.ludus.cloud) — this folder is the “what does that actually mean?” layer.

| Doc | Read it when… |
|---|---|
| [Root README](../README.md) | You want the high-level map of blueprints, templates, and roles |
| [Ansible catalog](../ansible/README.md) | You need the role list, versions, and stack wiring |
| [Templates & Packer for dummies](./templates-for-dummies.md) | You want the ISO → golden VM → range clone story, or a build just ate your VM |
| [Templates README](../templates/README.md) | You need this source’s ISO pins, inventory notes, and shared-storage caveats |
| [Contributing](../CONTRIBUTING.md) | You are adding a blueprint, role, or template |
| [Changelog](../CHANGELOG.md) | You are writing release notes — put them under `[Unreleased]` |

## Role deep-dives

| Role | README |
|---|---|
| Security Onion setup + heal | [`ludus_securityonion`](../ansible/roles/ludus_securityonion/README.md) |
| Fleet agents on endpoints | [`ludus_so_elastic_agent`](../ansible/roles/ludus_so_elastic_agent/README.md) |
| Trial / Defend / Kibana rules | [`ludus_so_elastic_security`](../ansible/roles/ludus_so_elastic_security/README.md) |
| Sysmon on Windows | [`ludus_sysmon`](../ansible/roles/ludus_sysmon/README.md) |
| Adaptix Qt deps | [`ludus_adaptix_deps`](../ansible/roles/ludus_adaptix_deps/README.md) |
| Adaptix v1.2 runtime fix | [`ludus_adaptix_c2_fix`](../ansible/roles/ludus_adaptix_c2_fix/README.md) |

## Official Ludus (go deeper)

- [Templates](https://docs.ludus.cloud/docs/using-ludus/templates)
- [Sources](https://docs.ludus.cloud/docs/using-ludus/sources)
- [Networking / packet capture](https://docs.ludus.cloud/docs/networking#packet-capture)

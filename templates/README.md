# Ludus Templates

Self-contained [Packer](https://packer.io/) templates for this source.
Each subdirectory builds one Ludus VM template. See
https://docs.ludus.cloud/docs/templates and
https://docs.ludus.cloud/docs/using-ludus/sources for authoring rules.

## Installing

```bash
ludus source add https://github.com/ryokubaka/ludus-source-meow.git
ludus templates build -n <template-name>
```

## Available templates

| Template | Description |
|---|---|
| `securityonion-2.4-x64-template` | Security Onion 2.4.211 base (Oracle Linux 9 ISO). `so-setup` at deploy. |
| `securityonion-3-x64-template` | Security Onion 3.1.0 base. `so-setup` at deploy. |

### Security Onion notes

- Uses the **stock SO ISO kickstart**. Custom HTTP/OEMDRV `ks.cfg` overrides keep
  losing to the ISO’s embedded `ks=cdrom` (WARNING / type **yes** screen).
- Packer `boot_command` waits ~75s, then types: `yes` → username `onion` →
  password `onion` twice. After that Anaconda/`%post` runs unattended (long
  rsync of SO + docker images).
- **Finished template creds: `onion` / `onion`.** Ansible strips so-setup
  autostart and installs `qemu-guest-agent`.
- Monitor progress on the Packer build VM **Proxmox console**. You should see
  the WARNING briefly, then prompts answered, then package install / copy.
- `boot_iso { iso_download_pve = true }` — Proxmox pulls the ISO onto
  `iso_storage_pool` (avoid filling user `packer_cache`).
- Ensure ISO datastore has ~15–25 GB free per SO ISO.
- Build budget ~1–2 h (`ssh_timeout` 120m).

```bash
# on Ludus host — clear leftover packer cache if needed
rm -rf /opt/ludus/users/<user>/packer/packer_cache/downloaded_iso_path/*
df -h /opt/ludus
```

## Authoring checklist

1. Create `templates/<name>/`
2. Add `<name>.pkr.hcl` with `description` and `icon_path` variables
3. Linux: kickstart or ISO-native automation · Windows: `Autounattend.xml`
4. Document the `*-template` name in this README
5. After `source add`, build: `ludus templates build -n <name>`

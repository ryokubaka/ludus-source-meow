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

- OS install is unattended via Packer HTTP kickstart; **so-setup is not run in Packer**.
- Template creds: `onion` / `onion`
- Disk 200G; first build downloads a large ISO and can take a long time.
- SO ISO embeds `ks=cdrom` with an interactive **type yes** warning. That is *not*
  Anaconda progress — it means our kickstart lost. Templates boot with
  `ks=` + `inst.ks=` both set to Packer HTTP `ks.cfg` (`ip=dhcp` required) and
  still attach an OEMDRV CD as fallback. If console shows the WARNING prompt,
  abort and re-sync/rebuild — do not wait.
- Real Anaconda progress: same Proxmox **Console** on the Packer build VM —
  package install / formatting / `%post` copy, then reboot to login.
- Packer needs `qemu_agent = true` plus `qemu-guest-agent` in kickstart — otherwise
  Proxmox never reports a DHCP IP and SSH wait loops forever (`500 QEMU guest agent
  is not running`). Agent probes fail during Anaconda; succeed after first reboot.
- Templates use `boot_iso { iso_download_pve = true }` so Proxmox pulls the ISO onto
  `iso_storage_pool` instead of filling `/opt/ludus/users/<user>/packer/packer_cache`
  (SO ISOs are multi-GB; local cache download hits `no space left on device`).
- Ensure the Proxmox ISO datastore has enough free space (~15–25 GB per SO ISO).
- If a prior failed build left a partial ISO in packer_cache, clear it:

```bash
# on Ludus host
rm -rf /opt/ludus/users/<user>/packer/packer_cache/downloaded_iso_path/*
df -h /opt/ludus
```

## Authoring checklist

1. Create `templates/<name>/`
2. Add `<name>.pkr.hcl` with `description` and `icon_path` variables
3. Linux: `http/` kickstart · Windows: `Autounattend.xml`
4. Document the `*-template` name in this README
5. After `source add`, build: `ludus templates build -n <name>`

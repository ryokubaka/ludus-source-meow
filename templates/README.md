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

- **Goal of Packer:** unattended OS + SSH + `qemu-guest-agent`, **no so-setup**.
  Range deploy runs `ludus_securityonion` (`so-setup`) later.
- Custom `http/ks.cfg` (HTTP + OEMDRV) overrides ISO `ks=cdrom`. Boot sets both
  `ks=` and `inst.ks=` to Packer HTTP. Must type at the boot menu immediately
  (no long pre-wait — menu auto-boots stock ks).
- Custom ks: auto `reboot --eject`, installs/enables `qemu-guest-agent`, strips
  so-setup shell hooks. Template creds: `onion` / `onion`.
- **Success signals:** Packer log shows SSH connected → ansible → template
  created. Console must **not** stop on WARNING/yes, Press Enter to reboot, or
  so-setup TUI. If WARNING appears, boot override failed — abort.
- `boot_iso { iso_download_pve = true }` — ISO on Proxmox datastore, not user
  packer_cache. Keep ~15–25 GB free per SO ISO.
- Build budget ~1–2 h (`ssh_timeout` 120m).

## Authoring checklist

1. Create `templates/<name>/`
2. Add `<name>.pkr.hcl` with `description` and `icon_path` variables
3. Linux: kickstart or ISO-native automation · Windows: `Autounattend.xml`
4. Document the `*-template` name in this README
5. After `source add`, build: `ludus templates build -n <name>`

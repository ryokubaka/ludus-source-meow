# Ludus Templates

Self-contained [Packer](https://packer.io/) templates for this source.

## Available templates

| Template | Description |
|---|---|
| `securityonion-2.4-x64-template` | Security Onion 2.4.211 base. `so-setup` at deploy. |
| `securityonion-3-x64-template` | Security Onion 3.1.0 base. `so-setup` at deploy. |

### Security Onion automation model

**Packer goal:** OS + SSH harden only. **No so-setup** (range role does that).

1. **Kickstart CD on `/dev/sr1`** (Packer `additional_iso_files` / OEMDRV). Boot sets
   `ks=cdrom:/dev/sr1:/ks.cfg` + `inst.ks=...` so Anaconda does **not** use the SO
   ISO’s embedded `ks=cdrom` on `sr0` ([CentOS 8 / Packer pattern](https://stackoverflow.com/questions/65099940)).
2. Custom `http/ks.cfg`: auto-reboot, `qemu-guest-agent`, strip so-setup hooks,
   creds `onion`/`onion`.
3. **`communicator = "none"`** — Packer does **not** wait on QEMU guest-agent IP
   (stock SO path never had an agent → endless `500` / no ansible).
4. **`shell-local` as the Ludus user** (Ludus never runs Packer as root): fixed MAC
   in HCL → readable dnsmasq lease → SSH → ansible. No `qm` / sudo on the host.
5. Inside the guest, ansible uses `onion`’s passwordless sudo (kickstart).

### Verify the synced template is live

Packer log **must** show:

- `Creating CD disk` / `CD label is set to OEMDRV`
- `Waiting 12s for boot` (not `Waiting 1m15s`)
- **No** long `Waiting for SSH` / guest-agent 500 loop before provision

Console **must not** show WARNING / type yes. If it does, `sr1` kickstart lost — abort.

### Ops

```bash
ludus templates build -n securityonion-2.4-x64-template
# ISO datastore needs ~15–25 GB free; build ~1–2 h
```

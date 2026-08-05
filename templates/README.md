# Ludus Templates

| Template | Description |
|---|---|
| `securityonion-2.4-x64-template` | SO 2.4.211 base. `so-setup` at range deploy. |
| `securityonion-3-x64-template` | SO 3.1.0 base. `so-setup` at range deploy. |

## Security Onion — how Packer works here

Normal Ludus templates: kickstart installs `qemu-guest-agent` → Packer SSH via Proxmox.

SO stock ISO: interactive install, **no guest-agent**, OEMDRV kickstart override fails.
So this template:

1. Types stock prompts (`yes` / `onion`×3 / Enter ~10m).
2. `boot=order=scsi0;ide0` so reboot hits disk not ISO.
3. `communicator=none` + shell-local: SSH-scan Ludus NAT DHCP pool **`.50–.100`**
   ([Ludus networking](https://docs.ludus.cloud/docs/networking)) for `onion`/`onion`.
4. Ansible installs guest-agent + strips so-setup autostart.

```bash
ludus templates build -n securityonion-2.4-x64-template
```

# Ludus Templates

| Template | Description |
|---|---|
| `securityonion-2.4-x64-template` | SO 2.4.211 base. `so-setup` at range deploy. |
| `securityonion-3-x64-template` | SO 3.1.0 base. `so-setup` at range deploy. |

## Security Onion automation

OEMDRV kickstart does **not** override this ISO. Path:

1. **`boot_command`** — stock prompts + periodic Enter for reboot prompt.
2. **`boot = "order=scsi0;ide0"`** — disk first after install (avoids ISO re-boot loop).
3. **`communicator = "none"`** + **shell-local** — fixed MAC → dnsmasq → SSH → ansible.
4. Creds: `onion` / `onion`. so-setup = deploy-time only.

```bash
ludus templates build -n securityonion-2.4-x64-template
# ~1.5–2.5 hours
```

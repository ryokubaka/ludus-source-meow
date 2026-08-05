# Ludus Templates

| Template | Description |
|---|---|
| `securityonion-2.4-x64-template` | SO 2.4.211 base. `so-setup` at range deploy. |
| `securityonion-3-x64-template` | SO 3.1.0 base. `so-setup` at range deploy. |

## Security Onion automation (evidence-driven)

OEMDRV / `sr1` kickstart **does not** override this ISO’s embedded `ks=cdrom`
(console always hits WARNING). Working path:

1. **`boot_command`** types stock prompts: `yes` → `onion` / `onion` / `onion`,
   waits for install, presses Enter at “Press Enter to reboot”, waits for boot.
2. **`communicator = "none"`** — no Packer guest-agent IP wait (stock image has
   no agent).
3. **`shell-local` as Ludus user** — fixed MAC → dnsmasq lease → SSH → ansible
   (install `qemu-guest-agent`, strip so-setup autostart). No host `qm`/sudo.
4. Finished template creds: `onion` / `onion`. **so-setup is deploy-time only.**

### Sync checks

Packer log should show `Waiting 1m15s` (yes prompt delay), then later
`Waiting 55m0s` (install), then shell-local `ssh_ready` / `ansible_start`.

Console: WARNING briefly, then auto answers — not stuck on yes or Enter-to-reboot.

```bash
ludus templates build -n securityonion-2.4-x64-template
# ~1–2 hours; ISO datastore needs ~15–25 GB free
```

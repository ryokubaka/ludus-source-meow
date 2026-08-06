# Ludus Templates

| Template | Description |
|---|---|
| `securityonion-2.4-x64-template` | SO 2.4.211 base. `so-setup` at range deploy. |
| `securityonion-3-x64-template` | SO 3.1.0 base. `so-setup` at range deploy. |

## Security Onion Packer path

1. Stock ISO: `yes` / `onion`×3 / Enter (~10m) / reboot.
2. Login → **Cancel so-setup** (autostarts; blocks shell/DHCP).
3. Strip so-setup from profiles; `nmcli`/`dhclient` + sshd.
4. shell-local SSH-scans Ludus DHCP **`192.0.2.50–100`**.
5. Ansible: guest-agent + harden. Creds: `onion`/`onion`. so-setup = deploy only.

Sync to `/opt/ludus/packer/securityonion-2.4/`. Log must show `H33-cancel-sosetup-20260805`, then `ssh_ready` on `192.0.2.x`. Console after keystrokes: shell, not hostname TUI.

```bash
ludus templates build -n securityonion-2.4-x64-template
```

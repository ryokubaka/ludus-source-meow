# Ludus Templates

| Template | Description |
|---|---|
| `securityonion-2.4-x64-template` | SO 2.4.211 base. `so-setup` at range deploy. |
| `securityonion-3-x64-template` | SO 3.1.0 base. `so-setup` at range deploy. |

## Security Onion Packer path (evidence-driven)

1. Stock ISO keystrokes (`yes` / `onion`×3 / Enter ~10m).
2. `boot=order=scsi0;ide0` → disk login (not ISO).
3. **Offline SO install leaves NIC without DHCP** (`lease_lines:0` while at
   `localhost login:`). After reboot: tty2 login → `nmcli`/`dhclient` + sshd.
4. shell-local SSH-scans Ludus DHCP pool **`192.0.2.50–100`**
   ([docs](https://docs.ludus.cloud/docs/networking)).
5. Ansible: guest-agent + strip so-setup. Creds: `onion` / `onion`.

Sync check: Packer must print `H32-netup-20260805` and later `ssh_ready` with a
`192.0.2.x` IP. Deploy script to `/opt/ludus/packer/securityonion-2.4/scripts/`.

```bash
ludus templates build -n securityonion-2.4-x64-template
```

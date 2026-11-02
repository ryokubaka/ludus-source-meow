# ludus_adaptix_c2_fix (1.0.0)

Post-configure **Adaptix C2 v1.2+** after [`badsectorlabs.ludus_adaptix_c2`](https://github.com/badsectorlabs/ludus_adaptix_c2) so the teamserver stays up under systemd.

## Why this role exists

The upstream Adaptix Ludus role targets an older layout:

- JSON profile at `/opt/adaptix/profile.json`
- Extender paths like `listener_beacon_http` / `agent_gopher` with `config.json`
- A systemd unit that enables `MemoryDenyWriteExecute` (breaks the Go runtime)

Adaptix **v1.2** expects:

- YAML profile (`-profile profile.yaml`) with `access_token_live_hours` / `refresh_token_live_hours`
- Renamed extenders (`beacon_listener_http`, `gopher_agent`, …) and `config.yaml`
- Absolute paths to certs, 404 page, and extender configs are safest on Ludus guests

Without this fix, `adaptix-c2.service` crash-loops with “Invalid profile” / missing extender files even though `make server` succeeded.

## What it does

1. Write `/opt/adaptix/profile.yaml` from the v1.2 template (port, endpoint, password, extenders, token TTLs)
2. Install `/etc/systemd/system/adaptix-c2.service` pointing at that YAML profile, without `MemoryDenyWriteExecute`
3. `daemon-reload`, enable, and start `adaptix-c2`

Variables fall back to the upstream role’s `ludus_adaptix_c2_*` defaults when those are already in scope.

## Blueprint usage

```yaml
roles:
  - name: ryokubaka.ludus_adaptix_deps
  - name: badsectorlabs.ludus_adaptix_c2
  - name: ryokubaka.ludus_adaptix_c2_fix
role_vars:
  ludus_adaptix_c2_install_server: true
  ludus_adaptix_c2_install_client: true
  ludus_adaptix_c2_version: v1.2
  ludus_adaptix_c2_go_version: "1.25.4"
  ludus_adaptix_c2_password: pass
```

Connect with `adaptixclient` → `https://127.0.0.1:4321/endpoint` (password from `ludus_adaptix_c2_password` / fix defaults).

## Role variables

| Variable | Default | Purpose |
|---|---|---|
| `ludus_adaptix_c2_fix_port` | `ludus_adaptix_c2_port` → `4321` | Teamserver listen port |
| `ludus_adaptix_c2_fix_endpoint` | `ludus_adaptix_c2_endpoint` → `/endpoint` | HTTPS path |
| `ludus_adaptix_c2_fix_password` | `ludus_adaptix_c2_password` → `pass` | Teamserver password |

## Prerequisites

- Upstream role has built `/opt/adaptix/dist/adaptixserver` and extenders under `/opt/adaptix/dist/extenders/`
- TLS material at `/opt/adaptix/server.rsa.crt` and `server.rsa.key` (upstream generate step)
- `404page.html` at `/opt/adaptix/404page.html`
- User `adaptix` exists (created by upstream)

## Notes

- Does not rebuild client/server; it only fixes runtime config.
- Upstream may still fail on legacy tasks (e.g. copying `Extenders/agent_gopher`); if you patch that role for v1.2 path names, keep this fix afterward so the unit/profile stay correct.
- Go **1.25.4** is required to *build* v1.2; pin `ludus_adaptix_c2_go_version` on the upstream role.

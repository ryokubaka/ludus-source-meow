# ludus_so_elastic_agent (1.0.12)

Deploys the Security Onion Elastic Agent to Ludus range endpoints so they enroll in Fleet policy `endpoints-initial`.

## Why this role exists

SO ships its own agent installers under `/nsm/elastic-fleet/so_agent-installers/`. Stock Elastic docs assume a different layout and hostname. On Ludus ranges you also need:

- Inter-VLAN firewall rules to Fleet (`8220`, `5055`, `8443`)
- SO `so-firewall` hostgroup `elastic_agent_endpoint` opened for the range CIDR
- Guest `/etc/hosts` (or Windows hosts) mapping **`manager` → SO IP** (Fleet outputs use that hostname)
- A reliable Windows install path: the SO MSI often exits 0 while QuietExec fails with `ERROR_INVALID_FUNCTION`, leaving no enrolled agent

This role packages that sequence and, by default, **uninstalls then re-enrolls** every run so a redeploy follows whichever SO instance is current (rebuild, 2.4 → 3.3, new certs).

## What it does

1. Resolve the SO manager (`{{ range_id }}-so` by default) and wait for `/etc/ludus-so-setup-complete` (rejects a marker without a real `so-firewall`)
2. Open `elastic_agent_endpoint` for the range CIDR
3. Fetch the Fleet enrollment token for `endpoints-initial` (or use an override)
4. Pull the SO-bundled installer from the manager (cached on the Ludus controller)
5. Optionally uninstall any existing agent (Linux `elastic-agent uninstall`, Windows service/MSI + Defend uninstall token when present)
6. Install:
   - **Linux** — `so-elastic-agent_linux_amd64` with `-token` / `-fleet`
   - **Windows** — MSI first; if msiexec reports success but no agent/service/marker, run `so-elastic-agent_windows_amd64.exe -token … -fleet …` directly and retry on transient I/O copy errors
7. Write a marker that records the manager identity (setup-marker hash + enrollment key id)

Skips the SO manager itself (`ludus_so_agent_skip_manager`). Apply on every endpoint that should enroll.

## Blueprint usage

**`depends_on` must be nested under the role object** (Ludus cross-VM ordering). VM-level `depends_on` is ignored.

```yaml
network:
  rules:
    - name: Allow targets to SO Fleet
      vlan_src: 10
      vlan_dst: 20
      protocol: tcp
      ports: "8220,5055,8443"
      action: ACCEPT

ludus:
  - vm_name: "{{ range_id }}-so"
    roles:
      - name: ryokubaka.ludus_securityonion

  - vm_name: "{{ range_id }}-dc01"
    roles:
      - name: ryokubaka.ludus_sysmon
      - name: ryokubaka.ludus_so_elastic_agent
        depends_on:
          - vm_name: "{{ range_id }}-so"
            role: ryokubaka.ludus_securityonion

  - vm_name: "{{ range_id }}-win11"
    roles:
      - name: ryokubaka.ludus_sysmon
      - name: ryokubaka.ludus_so_elastic_agent
        depends_on:
          - vm_name: "{{ range_id }}-so"
            role: ryokubaka.ludus_securityonion
```

`requirements.yml`:

```yaml
roles:
  - name: ryokubaka.ludus_securityonion
  - name: ryokubaka.ludus_so_elastic_agent
```

## Role variables

| Variable | Default | Purpose |
|---|---|---|
| `ludus_so_agent_manager` | `{{ range_id }}-so` | SO inventory hostname |
| `ludus_so_agent_manager_ip` | `""` | Override manager IP |
| `ludus_so_agent_policy_id` | `endpoints-initial` | Fleet policy for enrollment key |
| `ludus_so_agent_enrollment_token` | `""` | Skip Fleet API when set |
| `ludus_so_agent_fleet_url` | `https://<mgr>:8220` | Fleet Server URL |
| `ludus_so_agent_allow_cidr` | `10.<range>.0.0/16` | SO firewall hostgroup CIDR |
| `ludus_so_agent_setup_wait_timeout` | `600` | Seconds to wait for SO setup marker |
| `ludus_so_agent_reinstall` | `true` | Uninstall then enroll on every run |
| `ludus_so_agent_force` | `false` | With `reinstall: false`, reinstall even if marker matches |
| `ludus_so_agent_uninstall_before_install` | `true` | Uninstall prior agent before enroll |
| `ludus_so_agent_uninstall_token` | `""` | Override; empty uses Fleet uninstall token for the policy |
| `ludus_so_agent_skip_manager` | `true` | Never enroll the SO VM |
| `ludus_so_agent_windows_bootstrapper_name` | `so-elastic-agent_windows_amd64.exe` | SO bootstrapper next to the MSI payload |
| `ludus_so_agent_fix_manager_hosts` | `true` | Write `manager` → SO IP on the guest |

## Notes

- Ludus inter-VLAN default is DROP — add Fleet TCP ports toward the SO management VLAN.
- Installers are ~200–300MB; first fetch caches under `/tmp/ludus-so-elastic-agent-cache` on the Ludus host.
- Markers: `/etc/ludus-so-elastic-agent-installed` (Linux), `C:\ProgramData\ludus-so-elastic-agent-installed` (Windows).
- With `ludus_so_agent_reinstall: false`, install is skipped only when the marker `manager_id` matches this SO instance and the agent binary/service is present.
- Controller temp paths use the same `controller-remote-tmp.sh` pattern as `ludus_securityonion` (Ludus `ProtectHome=read-only`).
- Adding SO to an existing range: put this role on endpoints with role-level `depends_on`, then `ludus range deploy` (or `--only-roles` after SO is up).

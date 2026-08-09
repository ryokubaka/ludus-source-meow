# ludus_so_elastic_agent

Deploys the Security Onion Elastic Agent to Ludus range endpoints.

- Resolves the range SO manager (`{{ range_id }}-so` by default)
- Opens SO hostgroup `elastic_agent_endpoint` for the range CIDR (`so-firewall`)
- Fetches the Fleet enrollment token for `endpoints-initial`
- Pulls the SO-bundled installer from `/nsm/elastic-fleet/so_agent-installers/`
- Installs Linux (`so-elastic-agent_linux_amd64`) or Windows MSI with `-token` / `TOKEN=` + Fleet URL

Skips the SO manager itself. Apply this role on every endpoint VM that should enroll.

## Blueprint usage

```yaml
network:
  rules:
    - name: Allow targets to SO Fleet
      vlan_src: 10
      vlan_dst: 20
      protocol: tcp
      ports: [8220, 5055, 8443]
      action: ACCEPT
    - name: Allow Kali to SO Fleet
      vlan_src: 99
      vlan_dst: 20
      protocol: tcp
      ports: [8220, 5055, 8443]
      action: ACCEPT

ludus:
  - vm_name: "{{ range_id }}-so"
    roles:
      - name: ryokubaka.ludus_securityonion

  - vm_name: "{{ range_id }}-target"
    roles:
      - name: ryokubaka.ludus_so_elastic_agent
    depends_on:
      - vm_name: "{{ range_id }}-so"
        role: ryokubaka.ludus_securityonion

  - vm_name: "{{ range_id }}-win"
    windows: true
    roles:
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
| `ludus_so_agent_force` | `false` | Reinstall even if marker present |
| `ludus_so_agent_skip_manager` | `true` | Never enroll the SO VM |

## Notes

- Ludus inter-VLAN default is DROP — add Fleet TCP ports (8220 / 5055 / 8443) toward the SO management VLAN.
- Installers are ~200–300MB; first fetch caches under `/tmp/ludus-so-elastic-agent-cache` on the Ludus host.
- Marker files: `/etc/ludus-so-elastic-agent-installed` (Linux), `C:\ProgramData\ludus-so-elastic-agent-installed` (Windows).

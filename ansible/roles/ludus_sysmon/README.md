# ludus_sysmon

Installs Sysmon64 on Windows Ludus hosts and applies a lab config.

Security Onion `endpoints-initial` already collects `Microsoft-Windows-Sysmon/Operational` through `windows-endpoints`. This role installs the service that writes that channel. It does not change the Fleet policy.

The Sysinternals zip is downloaded on the Ansible controller and copied to the guest. Range Windows VMs use `testing.block_internet`, so the guest cannot download it.

## Blueprint usage

Put it on the Windows VMs, before the Fleet agent:

```yaml
roles:
  - name: ryokubaka.ludus_sysmon
  - name: ryokubaka.ludus_so_elastic_agent
    depends_on:
      - vm_name: "{{ range_id }}-so"
        role: ryokubaka.ludus_securityonion
```

## Role variables

| Variable | Default | Purpose |
|---|---|---|
| `ludus_sysmon_install_dir` | `C:\ProgramData\ludus\Sysmon` | Guest copy of the exe and config |
| `ludus_sysmon_url` | Sysinternals `Sysmon.zip` | Controller download |
| `ludus_sysmon_cache_dir` | `/tmp/ludus-sysmon-cache` | Controller cache |
| `ludus_sysmon_config_src` | `""` | Empty uses `files/sysmonconfig.xml` |
| `ludus_sysmon_force` | `false` | `Sysmon64 -u force` then install again |
| `ludus_sysmon_refresh_installer` | `false` | Re-download the zip |

A later run applies the config only when the file hash changed. `ludus_sysmon_force=true` reinstalls the service.

The bundled config (schema 4.90) logs process, network, unsigned image loads, LSASS access, interesting file creates, Run-key registry, DNS, drivers, remote threads, pipes, process tampering, and file deletes. Revocation checks are off.

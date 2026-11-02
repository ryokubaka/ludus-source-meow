# ludus_sysmon (1.0.5)

Installs Sysmon64 on Windows Ludus hosts and applies a lab config.

## Why this role exists

Security Onion’s `endpoints-initial` policy already collects `Microsoft-Windows-Sysmon/Operational` through `windows-endpoints`. Nothing writes that channel until Sysmon is installed. Range Windows VMs usually have `testing.block_internet: true`, so the guest cannot download Sysinternals itself.

This role downloads the zip on the **Ansible controller**, copies it to the guest, installs the service, and applies a schema 4.90 config aimed at lab detection (process, network, unsigned loads, LSASS access, interesting files, Run keys, DNS, drivers, remote threads, pipes, tampering, deletes). Revocation checks are off for lab speed.

It does **not** change Fleet policy — pair with `ludus_so_elastic_agent` for enrollment.

## Blueprint usage

Put it on Windows VMs **before** the Fleet agent:

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

## Notes

- Controller temp paths use `files/controller-remote-tmp.sh` (same Ludus `ProtectHome` pattern as the SO roles).
- To ship a custom config, set `ludus_sysmon_config_src` to a path readable by the controller play.

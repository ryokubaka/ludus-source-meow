# ludus_so_elastic_security

Apply to the **Security Onion manager** VM after `ryokubaka.ludus_securityonion`.

Mirrors the Elastic Security steps used by the GOAD-mod Security Onion extension:

1. **Trial license** — `POST _license/start_trial?acknowledge=true` (platinum-class features for 30 days)
2. **Elastic Defend** — switch `elastic-defend-endpoints` on `endpoints-initial` from SO default `DataCollection` (protections off) to `EDRComplete`, then set malware / ransomware / memory / behavior to **detect**
3. **Detection rules** — `POST /api/fleet/package_policies` for `security_detection_engine` on `endpoints-initial` (the Rules UI install), then bulk-enable every disabled rule

## endpoints-initial on Security Onion 3.3

Checked against a Security Onion 3.3 manager (Elastic **9.4.5**). Fleet shows five integrations on `endpoints-initial`, all namespace `default`, output `grid-logstash`:

| Integration policy | Package | This role |
|---|---|---|
| `elastic-defend-endpoints` | Elastic Defend **9.4.1** (`endpoint`) | Sets preset + protection mode |
| `osquery-endpoints` | Osquery Manager 1.31.0 | Left as so-setup shipped it |
| `system-endpoints` | System 2.22.3 | Left as so-setup shipped it |
| `windows-defender` | Custom Windows Event Logs 2.6.0 (`winlog`, Defender Operational) | Left as so-setup shipped it |
| `windows-endpoints` | Windows 3.0.0 | Sysmon stays on. Role also enables AppLocker, Packaged app, and Windows Defender. Install Sysmon with `ludus_sysmon` |

Defend 9.4.1 on stack 9.4.5 is the SO package pin, not a mismatch. The role selects `elastic-defend-endpoints` on `endpoints-initial` (not the first `endpoint` package, so a grid policy is not edited). It writes the preset on both `integration_config` (saved policy) and `_config` (SO create template), and sets `.mode` on the existing protection objects so 9.4 fields stay. `EDRComplete` itself enables prevent mode; the role then applies `ludus_so_elastic_security_defend_mode`.

Uses SO helpers (`so-elasticsearch-query`, Kibana/Fleet via `/opt/so/conf/elasticsearch/curl.config`).

## Where to see rules (important)

Rules enabled by this role live in **Kibana Security → Rules**, not the SOC “Detections” page.

- SOC UI (`https://<so>/`) → Sigma / ElastAlert style detections (different system)
- Kibana rules: `https://<so>/kibana/app/security/rules`

Use an analyst account that can open Kibana. Clear filters; prebuilt rules show under the Installed / Elastic rules list (**1832** after a successful run).

## Blueprint usage

```yaml
ludus:
  - vm_name: "{{ range_id }}-so"
    roles:
      - name: ryokubaka.ludus_securityonion
      - name: ryokubaka.ludus_so_elastic_security
    role_vars:
      ludus_so_install_type: standalone
```

List `ludus_securityonion` before `ludus_so_elastic_security` so setup finishes first.

`requirements.yml`:

```yaml
roles:
  - name: ryokubaka.ludus_securityonion
  - name: ryokubaka.ludus_so_elastic_security
```

## Role variables

| Variable | Default | Purpose |
|---|---|---|
| `ludus_so_elastic_security_start_trial` | `true` | Start Elastic trial if not already trial/platinum |
| `ludus_so_elastic_security_configure_defend` | `true` | Set Elastic Defend protections to detect mode |
| `ludus_so_elastic_security_defend_policy_name` | `elastic-defend-endpoints` | Integration policy to update |
| `ludus_so_elastic_security_agent_policy_id` | `endpoints-initial` | Agent policy that owns that integration |
| `ludus_so_elastic_security_defend_preset` | `EDRComplete` | Fleet Defend preset |
| `ludus_so_elastic_security_defend_mode` | `detect` | `detect` / `prevent` / `off` for all protection types |
| `ludus_so_elastic_security_defend_user_notify` | `true` | Endpoint-user popups for malware/ransomware/memory/behavior. SIEM alerts always fire in detect/prevent. Device-control popups left off (need USB deny_all). |
| `ludus_so_elastic_security_configure_windows_logs` | `true` | Enable AppLocker, Packaged app, and Windows Defender on `windows-endpoints` |
| `ludus_so_elastic_security_windows_policy_name` | `windows-endpoints` | Windows integration policy |
| `ludus_so_elastic_security_enable_rules` | `true` | Install the `security_detection_engine` Fleet package and enable its rules |
| `ludus_so_elastic_security_detection_engine_version` | `""` | Package version. Empty uses the latest Fleet has (the UI used `9.4.10` on Elastic 9.4.5) |
| `ludus_so_elastic_security_api_version` | `2023-10-31` | `elastic-api-version` for Kibana 9 detection-engine routes |
| `ludus_so_elastic_security_prepackaged_pause` | `120` | Seconds to wait for rules to appear after the Fleet package POST |
| `ludus_so_elastic_security_force` | `false` | Re-run when marker exists |
| `ludus_so_elastic_security_grant_admin` | `true` | Give the SOC account SOC `superuser`, every Kibana feature `.all` privilege, and a default space with nothing disabled |
| `ludus_so_elastic_security_admin_user` | `onionadmin@ludus.local` | Account to grant. Follows `ludus_so_web_user` when that is set |

## Notes

- The Rules UI installs prebuilt rules by adding Fleet package `security_detection_engine` to `endpoints-initial`. Enable sends `elastic-api-version: 2023-10-31` (required on Kibana 9.4) and uses one bulk call per batch. Elastic 9.4 also requires the `securitySolutionRules` enable/disable privilege, which the `so_elastic` superuser does not have; the role grants `ludus_so_detection_rules` and, if detection-engine enable is still denied, uses `POST /api/alerting/rules/_bulk_enable`. Rules Kibana rejects, usually ML rules when the manager has no ML node, stay disabled and are reported as `unenableable`. The role fails if none were enabled, or if disabled rules remain that Kibana did not reject.
- Marker: `/etc/ludus-so-elastic-security-complete`.
- The SOC account is granted the SOC `superuser` role and an Elasticsearch role (`ludus-all`). That role holds every Kibana feature `.all` privilege this stack advertises, including Security Alerts and Rules, plus cluster `all` and index `all` on `*` with restricted indices allowed. It does not also grant Kibana's base `all` privilege, which causes Kibana to ignore the feature privileges. The default space is left with no disabled features, because that space otherwise hides Detection & Response, the rule list, and cases. Log out and back in after the role runs so Kibana reloads the session.
- Trial is time-limited (~30 days).
- After Defend policy change, agents pick up policy on next check-in (usually ≤ a few minutes).

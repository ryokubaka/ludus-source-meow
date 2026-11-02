# ludus_so_elastic_security (1.0.13)

Apply to the **Security Onion manager** VM after `ryokubaka.ludus_securityonion`.

Mirrors the Elastic Security steps used by the GOAD-mod Security Onion extension so a Ludus SO lab is usable for detection engineering without clicking through Kibana by hand.

## Why this role exists

A fresh SO grid ships Elastic Defend in **DataCollection** (protections off), no trial features, and an empty Rules UI until someone installs the `security_detection_engine` package and enables rules. SOC accounts also lack the Kibana privileges needed to manage rules on Elastic 9.x.

This role turns that into a deterministic post-setup pass: trial → Defend detect mode → Windows log extras → prebuilt rules → admin grants.

## What it does

1. **Wait for Elasticsearch** — uses SO helpers (`so-elasticsearch-query`, curl config under `/opt/so/conf/elasticsearch/`)
2. **Trial license** — `POST _license/start_trial?acknowledge=true` when not already trial/platinum
3. **Elastic Defend** — on `elastic-defend-endpoints` / `endpoints-initial`, set preset `EDRComplete` and malware/ransomware/memory/behavior to **detect** (configurable)
4. **Windows logs** — enable AppLocker, Packaged app, and Windows Defender channels on `windows-endpoints` (Sysmon stays on; install Sysmon with `ludus_sysmon`)
5. **Detection rules** — Fleet package `security_detection_engine`, then the same “Add Elastic rules” install path, then bulk-enable. Installs in chunks and retries when Kibana drops the connection
6. **Admin grants** — SOC `superuser` plus Elasticsearch role `ludus-all` with Kibana feature `.all` privileges. On **SO 3**, `so-user` keeps SOC roles in Kratos and never rewrites `users_roles`; the role writes the ES mapping after `so-user` so Kibana authorization works

## endpoints-initial on Security Onion 3.3

Checked against SO 3.3 (Elastic **9.4.5**). Fleet shows five integrations on `endpoints-initial`, namespace `default`, output `grid-logstash`:

| Integration policy | Package | This role |
|---|---|---|
| `elastic-defend-endpoints` | Elastic Defend (`endpoint`) | Sets preset + protection mode |
| `osquery-endpoints` | Osquery Manager | Left as so-setup shipped it |
| `system-endpoints` | System | Left as so-setup shipped it |
| `windows-defender` | Custom Windows Event Logs (`winlog`) | Left as so-setup shipped it |
| `windows-endpoints` | Windows | Sysmon stays on; role enables AppLocker / Packaged app / Defender |

The role selects `elastic-defend-endpoints` on `endpoints-initial` (not the first `endpoint` package) so a grid policy is not edited. It writes the preset on both `integration_config` and `_config`, and sets `.mode` on existing protection objects.

## Where to see rules

Rules live in **Kibana Security → Rules**, not the SOC “Detections” page.

- SOC UI (`https://<so>/`) → Sigma / ElastAlert style detections (different system)
- Kibana rules: `https://<so>/kibana/app/security/rules`

Use an analyst account that can open Kibana. Clear filters; prebuilt rules show under Installed / Elastic rules (~1900 after a successful run). Log out and back in after grants so the session reloads.

## Blueprint usage

```yaml
ludus:
  - vm_name: "{{ range_id }}-so"
    roles:
      - name: ryokubaka.ludus_securityonion
      - name: ryokubaka.ludus_so_elastic_security
    role_vars:
      ludus_so_install_type: standalone
      ludus_so_expect_version: "3.3"   # optional; SO3 labs
```

List `ludus_securityonion` before this role so setup finishes first.

## Role variables

| Variable | Default | Purpose |
|---|---|---|
| `ludus_so_elastic_security_start_trial` | `true` | Start Elastic trial if not already trial/platinum |
| `ludus_so_elastic_security_configure_defend` | `true` | Set Elastic Defend protections |
| `ludus_so_elastic_security_defend_policy_name` | `elastic-defend-endpoints` | Integration policy to update |
| `ludus_so_elastic_security_agent_policy_id` | `endpoints-initial` | Agent policy that owns that integration |
| `ludus_so_elastic_security_defend_preset` | `EDRComplete` | Fleet Defend preset |
| `ludus_so_elastic_security_defend_mode` | `detect` | `detect` / `prevent` / `off` |
| `ludus_so_elastic_security_defend_user_notify` | `true` | Endpoint popups for malware/ransomware/memory/behavior |
| `ludus_so_elastic_security_configure_windows_logs` | `true` | Enable AppLocker / Packaged app / Defender on `windows-endpoints` |
| `ludus_so_elastic_security_windows_policy_name` | `windows-endpoints` | Windows integration policy |
| `ludus_so_elastic_security_enable_rules` | `true` | Install detection-engine package and enable rules |
| `ludus_so_elastic_security_detection_engine_version` | `""` | Empty = latest Fleet has |
| `ludus_so_elastic_security_api_version` | `2023-10-31` | `elastic-api-version` for Kibana 9 routes |
| `ludus_so_elastic_security_prepackaged_pause` | `120` | Seconds to wait after Fleet package POST |
| `ludus_so_elastic_security_force` | `false` | Re-run when marker exists |
| `ludus_so_elastic_security_grant_admin` | `true` | SOC superuser + Kibana/ES privileges |
| `ludus_so_elastic_security_admin_user` | follows `ludus_so_web_user` | Account to grant |

## Notes

- Marker: `/etc/ludus-so-elastic-security-complete`. Rule install still runs when needed even if a stale marker exists.
- Elastic 9.4 needs `securitySolutionRules` enable privileges; `so_elastic` alone is not enough. The role grants `ludus_so_detection_rules` and can fall back to `POST /api/alerting/rules/_bulk_enable`.
- Rules Kibana rejects (often ML rules with no ML node) stay disabled and are reported as `unenableable`. The role fails if nothing was enabled, or if other disabled rules remain.
- Trial is ~30 days. Agents pick up Defend policy on the next check-in.
- Do not also grant Kibana base `all` on the ES role — that causes Kibana to ignore feature privileges. Default space should have no disabled features or Detection & Response stays hidden.

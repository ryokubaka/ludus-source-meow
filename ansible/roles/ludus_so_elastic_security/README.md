# ludus_so_elastic_security

Apply to the **Security Onion manager** VM after `ryokubaka.ludus_securityonion`.

Mirrors [GOAD-mod `extensions/elk`](https://github.com/) Elastic setup:

1. **Trial license** — `POST _license/start_trial?acknowledge=true` (platinum-class features for 30 days)
2. **Elastic Defend** — switch `endpoints-initial` from SO default `DataCollection` (protections off) to `EDRComplete` with malware / ransomware / memory / behavior in **detect** mode
3. **Detection rules** — `PUT /api/detection_engine/rules/prepackaged`, then bulk-enable every disabled rule

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
| `ludus_so_elastic_security_defend_preset` | `EDRComplete` | Fleet Defend preset |
| `ludus_so_elastic_security_defend_mode` | `detect` | `detect` / `prevent` / `off` for all protection types |
| `ludus_so_elastic_security_defend_user_notify` | `true` | Endpoint-user popups for malware/ransomware/memory/behavior. SIEM alerts always fire in detect/prevent. Device-control popups left off (need USB deny_all). |
| `ludus_so_elastic_security_enable_rules` | `true` | Install + enable prepackaged rules |
| `ludus_so_elastic_security_prepackaged_pause` | `120` | Seconds to wait after prepackaged install |
| `ludus_so_elastic_security_force` | `false` | Re-run when marker exists |

## Notes

- Prepackaged install can take several minutes; enable loops process 100 rules at a time.
- Marker: `/etc/ludus-so-elastic-security-complete`.
- Trial is time-limited (~30 days).
- After Defend policy change, agents pick up policy on next check-in (usually ≤ a few minutes).

# Security Onion 2.4 Lab

Standalone Security Onion 2.4 with a `meow.local` domain (Win2019 DC + domain-joined Win11), Kali attacker with [Adaptix C2](https://github.com/badsectorlabs/ludus_adaptix_c2), and Fleet agents on the AD hosts. The `ludus_securityonion` role attaches SO sniff `net1` during Ludus deploy and enables bridge hub-mode for VLAN 10 capture.

## Quick Start

```bash
ludus source add https://github.com/ryokubaka/ludus-source-meow --all
ludus templates build -n securityonion-2.4-x64-template,win2019-server-x64-template,win11-22h2-x64-enterprise-template,kali-x64-desktop-template
ludus blueprint apply ryokubaka-ludus-source-meow/securityonion-lab
# Deploy via Ludus CLI or LUX:
ludus range deploy
```

## Network Diagram

```mermaid
graph TB
    subgraph VLAN10["VLAN 10 - AD targets sniffed"]
        DC["dc01 meow.local<br/>10.X.10.10"]
        WIN11["win11 member<br/>10.X.10.11"]
        SNIFF["SO net1 sniff"]
    end
    subgraph VLAN20["VLAN 20 - SOC"]
        SO["so<br/>10.X.20.20"]
    end
    subgraph VLAN99["VLAN 99 - Attack"]
        KALI["kali + Adaptix<br/>10.X.99.1"]
    end
    KALI -.-> DC
    KALI -.-> WIN11
    DC --- SNIFF
    WIN11 --- SNIFF
    SO --- SNIFF
```

> Replace `X` with your range's second octet (`ludus range list`).

## VM Details

| VM Name | Template | IP | Role |
|---|---|---|---|
| `{{ range_id }}-so` | securityonion-2.4-x64-template | 10.X.20.20 | Standalone SO |
| `{{ range_id }}-dc01` | win2019-server-x64-template | 10.X.10.10 | primary-dc `meow.local` + Fleet agent |
| `{{ range_id }}-win11` | win11-22h2-x64-enterprise-template | 10.X.10.11 | domain member + Fleet agent |
| `{{ range_id }}-kali` | kali-x64-desktop-template | 10.X.99.1 | attacker + Adaptix C2 |

**RAM required:** ~44 GB (SO 8–24 + DC 4 + Win11 4 + Kali 4)  
**SO mode:** Standalone (`so-setup iso standalone-net`)  
**Domain:** `meow.local`

## Credentials

| Account | Username | Password | Scope |
|---|---|---|---|
| OS | onion | onion | SO SSH (template default) |
| SOC | onionadmin@ludus.local | 0n10nAdm1n! | Security Onion Console |
| Domain admin | `MEOW\domainadmin` | `password` | `meow.local` (Ludus defaults) |
| Domain user | `MEOW\domainuser` | `password` | `meow.local` |
| Windows local | `localuser` | `password` | DC / Win11 local admin |
| Kali | kali | kali | attacker |
| Adaptix | any username | `pass` | teamserver `localhost:4321` /endpoint |

SOC UI: `https://10.X.20.20`  
Adaptix: on Kali run `adaptixclient`, connect to `https://127.0.0.1:4321/endpoint` (password `pass`). WireGuard can reach Kali `:4321`.

## Sniff NIC lifecycle

During deploy, `ryokubaka.ludus_securityonion`:

1. Adds SO `net1` on Proxmox (tagged VLAN 10, no IP) via Ludus Proxmox API
2. Sets `bridge-ageing 0` on `vmbr10XX` when the Ludus host can reach the bridge (local or SSH)
3. Waits for the guest to see the second NIC, then runs `so-setup iso standalone-net`

[LUX](https://github.com/ryokubaka/ludus-ux) enables hub-mode during deploy and may attach `net1` only after Ludus finishes IP config (attaching earlier breaks Ludus MAC→iface lookup when mgmt and sniff share a VLAN tag). Cleans up on range delete.

## Adding SO / agents to an existing range

Fleet agents use **role-level** `depends_on` so Ludus runs `ludus_securityonion` before enrollment:

```yaml
roles:
  - name: ryokubaka.ludus_so_elastic_agent
    depends_on:
      - vm_name: "{{ range_id }}-so"
        role: ryokubaka.ludus_securityonion
```

VM-level `depends_on` is ignored by Ludus.

## Requirements

- Ludus v2.0+
- Templates built: `securityonion-2.4-x64-template`, `win2019-server-x64-template`, `win11-22h2-x64-enterprise-template`, `kali-x64-desktop-template`
- Galaxy role: `badsectorlabs.ludus_adaptix_c2` (declared in `requirements.yml`)

# Security Onion 3 Lab

Standalone Security Onion 3 with a Debian target and Kali. Same topology as `securityonion-lab`; uses `securityonion-3-x64-template`.

## Quick Start

```bash
ludus source add https://github.com/ryokubaka/ludus-source-meow --all
ludus templates build -n securityonion-3-x64-template
ludus blueprint apply ryokubaka-ludus-source-meow/securityonion3-lab
ludus range deploy
```

## Network Diagram

```mermaid
graph TB
    subgraph VLAN10["VLAN 10 - Targets sniffed"]
        TARGET["target<br/>10.X.10.10"]
        SNIFF["SO net1 sniff"]
    end
    subgraph VLAN20["VLAN 20 - SOC"]
        SO["so<br/>10.X.20.20"]
    end
    subgraph VLAN99["VLAN 99 - Attack"]
        KALI["kali<br/>10.X.99.1"]
    end
    KALI -.-> TARGET
    TARGET --- SNIFF
    SO --- SNIFF
```

## Credentials

| Account | Username | Password | Scope |
|---|---|---|---|
| OS | onion | onion | SO SSH |
| SOC | onionadmin@ludus.local | 0n10nAdm1n! | Console |
| Kali | kali | kali | attacker |

SOC: `https://10.X.20.20` — `ludus_securityonion` attaches sniff `net1` during deploy.

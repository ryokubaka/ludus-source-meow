#!/bin/bash
# Collect runtime evidence for Packer SO template debug (session d940ab).
# Run ON Ludus/Proxmox host: bash debug-packer-state.sh [vmid]
# Optional: copy NDJSON lines into workspace debug-d940ab.log
set -euo pipefail
VMID="${1:-110}"
LOG_TAG="so-packer-debug"
ts() { date +%s%3N 2>/dev/null || date +%s000; }

emit() {
  local hid="$1" msg="$2" data="$3"
  printf '{"sessionId":"d940ab","hypothesisId":"%s","location":"debug-packer-state.sh","message":"%s","data":%s,"timestamp":%s}\n' \
    "$hid" "$msg" "$data" "$(ts)"
}

echo "=== $LOG_TAG vmid=$VMID ===" >&2

# H1: reboot-prompt / power / agent
CFG="$(qm config "$VMID" 2>/dev/null || true)"
AGENT_LINE="$(echo "$CFG" | grep -E '^agent:' || echo 'agent:missing')"
STATUS="$(qm status "$VMID" 2>/dev/null || true)"
emit "H1" "vm_power_and_agent_config" \
  "$(printf '{"vmid":"%s","status":"%s","agent_line":"%s"}' "$VMID" "$STATUS" "$AGENT_LINE")"

# H2: guest agent reachable?
AGENT_ERR=""
AGENT_OK=0
if qm agent "$VMID" ping >/dev/null 2>&1; then
  AGENT_OK=1
else
  AGENT_ERR="$(qm agent "$VMID" ping 2>&1 | tr '\n' ' ' | cut -c1-200)"
fi
emit "H2" "guest_agent_ping" \
  "$(printf '{"ok":%s,"error":"%s"}' "$AGENT_OK" "$(echo "$AGENT_ERR" | sed 's/"/\\"/g')")"

# H2b: try network-get-interfaces
IPS=""
if [ "$AGENT_OK" = "1" ]; then
  IPS="$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | head -c 500 | tr '\n' ' ' | sed 's/"/\\"/g' || true)"
fi
emit "H2" "guest_agent_interfaces" "$(printf '{"ips_snippet":"%s"}' "$IPS")"

# H4: DHCP leases mentioning this VM MAC
MAC="$(echo "$CFG" | sed -n 's/^net0:.*mac=\([0-9A-Fa-f:]*\).*/\1/p' | head -1)"
LEASE=""
if [ -n "$MAC" ]; then
  for f in /var/lib/misc/dnsmasq.leases /var/lib/dnsmasq/dnsmasq.leases; do
    [ -f "$f" ] || continue
    LEASE="$(grep -i "$MAC" "$f" 2>/dev/null | head -1 || true)"
  done
fi
emit "H4" "dhcp_lease_for_mac" \
  "$(printf '{"mac":"%s","lease":"%s"}' "$MAC" "$(echo "$LEASE" | sed 's/"/\\"/g')")"

# H3: so-setup autostart markers (needs SSH; try lease IP or skip)
SSH_IP="$(echo "$LEASE" | awk '{print $3}')"
SOSETUP="unknown"
if [ -n "$SSH_IP" ] && command -v sshpass >/dev/null 2>&1; then
  SOSETUP="$(sshpass -p 'onion' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    "onion@${SSH_IP}" 'grep -n so-setup ~/.bashrc ~/.bash_profile 2>/dev/null | head -20' 2>/dev/null \
    | tr '\n' ';' | sed 's/"/\\"/g' || echo 'ssh_failed')"
elif [ -n "$SSH_IP" ]; then
  SOSETUP="sshpass_missing_ip=${SSH_IP}"
fi
emit "H3" "sosetup_bashrc_markers" "$(printf '{"ssh_ip":"%s","markers":"%s"}' "$SSH_IP" "$SOSETUP")"

# H5: is packer still running?
PACKER_PIDS="$(pgrep -af '[p]acker' 2>/dev/null | head -5 | tr '\n' ';' | sed 's/"/\\"/g' || true)"
emit "H5" "packer_processes" "$(printf '{"procs":"%s"}' "$PACKER_PIDS")"

echo "=== paste NDJSON lines above into workspace debug-d940ab.log ===" >&2

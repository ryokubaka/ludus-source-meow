#!/bin/bash
# Packer shell-local provisioner (runs on Ludus/Proxmox host).
set -euo pipefail

VM_NAME="${VM_NAME:-securityonion-3-x64-template}"
SSH_USER="${SSH_USER:-onion}"
SSH_PASS="${SSH_PASS:-onion}"
PLAYBOOK="${PLAYBOOK:-ansible/reset-ssh-host-keys.yml}"
ANSIBLE_HOME="${ANSIBLE_HOME:-/opt/ludus/users/catshadowstep/.ansible}"
MAX_WAIT_SEC="${MAX_WAIT_SEC:-3600}"
POLL_SEC=10

ts() { date +%s%3N 2>/dev/null || echo "$(date +%s)000"; }
log_ndjson() {
  printf '%s\n' "{\"sessionId\":\"d940ab\",\"runId\":\"post-fix\",\"hypothesisId\":\"$1\",\"location\":\"packer-provision-via-dhcp.sh\",\"message\":\"$2\",\"data\":$3,\"timestamp\":$(ts)}"
}

log_ndjson "H7" "provision_script_start" "{\"vm_name\":\"${VM_NAME}\"}"

VMID="$(qm list 2>/dev/null | awk -v n="$VM_NAME" '$0 ~ n {print $1; exit}')"
if [ -z "$VMID" ]; then
  log_ndjson "H7" "vmid_not_found" "{\"vm_name\":\"${VM_NAME}\"}"
  echo "ERROR: no VM named ${VM_NAME}" >&2
  exit 1
fi

MAC="$(qm config "$VMID" | sed -n 's/^net0:.*mac=\([0-9A-Fa-f:]*\).*/\1/pi' | head -1)"
if [ -z "$MAC" ]; then
  echo "ERROR: no net0 mac on VM ${VMID}" >&2
  exit 1
fi

find_ip() {
  local mac_l f line ip
  mac_l="$(echo "$MAC" | tr 'A-F' 'a-f')"
  for f in /var/lib/misc/dnsmasq.leases /var/lib/dnsmasq/dnsmasq.leases /var/lib/ludus/dnsmasq.leases; do
    [ -f "$f" ] || continue
    line="$(grep -i "$mac_l" "$f" 2>/dev/null | tail -1 || true)"
    [ -n "$line" ] || continue
    ip="$(echo "$line" | awk '{print $3}')"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  ip neigh 2>/dev/null | grep -i "$mac_l" | awk '{print $1}' | head -1 || true
}

IP=""
elapsed=0
while [ "$elapsed" -lt "$MAX_WAIT_SEC" ]; do
  IP="$(find_ip || true)"
  if [ -n "$IP" ]; then
    if command -v sshpass >/dev/null 2>&1; then
      if sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 "${SSH_USER}@${IP}" 'echo ok' >/dev/null 2>&1; then
        break
      fi
    elif nc -z -w 3 "$IP" 22 2>/dev/null; then
      break
    fi
  fi
  sleep "$POLL_SEC"
  elapsed=$((elapsed + POLL_SEC))
done

if [ -z "$IP" ]; then
  log_ndjson "H4" "dhcp_ip_timeout" "{\"mac\":\"${MAC}\",\"waited\":${elapsed}}"
  exit 1
fi
log_ndjson "H4" "ssh_ready" "{\"ip\":\"${IP}\",\"waited\":${elapsed}}"

sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "${SSH_USER}@${IP}" "echo '${SSH_PASS}' | sudo -S bash -c '
    dnf install -y qemu-guest-agent 2>/dev/null || true
    systemctl enable --now qemu-guest-agent 2>/dev/null || true
    for f in /home/onion/.bash_profile /home/onion/.bashrc /root/.bash_profile /root/.bashrc; do
      [ -f \"\$f\" ] && sed -i \"/so-setup/d;/SecurityOnion\\/setup/d\" \"\$f\" || true
    done
  '" || true

INV="$(mktemp)"
printf '[all]\n%s ansible_user=%s ansible_password=%s ansible_become_password=%s ansible_python_interpreter=/usr/bin/python3 ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"\n' \
  "$IP" "$SSH_USER" "$SSH_PASS" "$SSH_PASS" >"$INV"

export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_HOME="${ANSIBLE_HOME}"
mkdir -p "${ANSIBLE_HOME}/tmp" 2>/dev/null || true

log_ndjson "H5" "ansible_start" "{\"ip\":\"${IP}\"}"
ansible-playbook -i "$INV" "$PLAYBOOK"
RC=$?
rm -f "$INV"
log_ndjson "H5" "ansible_finished" "{\"rc\":${RC}}"
exit "$RC"

#!/bin/bash
# Packer shell-local (Ludus/Proxmox host). DHCP → SSH → ansible.
# Must survive non-root Packer user (use sudo for qm) and long install times.
set -u

VM_NAME="${VM_NAME:-securityonion-2.4-x64-template}"
SSH_USER="${SSH_USER:-onion}"
SSH_PASS="${SSH_PASS:-onion}"
PLAYBOOK="${PLAYBOOK:-ansible/reset-ssh-host-keys.yml}"
ANSIBLE_HOME="${ANSIBLE_HOME:-/opt/ludus/users/catshadowstep/.ansible}"
MAX_WAIT_SEC="${MAX_WAIT_SEC:-7200}"
POLL_SEC=15

ts() { date +%s%3N 2>/dev/null || echo "$(date +%s)000"; }
log_ndjson() {
  # #region agent log
  printf '%s\n' "{\"sessionId\":\"d940ab\",\"runId\":\"post-fix\",\"hypothesisId\":\"$1\",\"location\":\"packer-provision-via-dhcp.sh\",\"message\":\"$2\",\"data\":$3,\"timestamp\":$(ts)}"
  # #endregion
}

# qm needs root on Proxmox; Packer often runs as the Ludus user.
qm_cmd() {
  if command -v qm >/dev/null 2>&1 && qm list >/dev/null 2>&1; then
    qm "$@"
    return $?
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo -n qm "$@" 2>/dev/null || sudo qm "$@"
    return $?
  fi
  return 127
}

log_ndjson "H7" "provision_script_start" "{\"vm_name\":\"${VM_NAME}\",\"whoami\":\"$(whoami 2>/dev/null || echo unknown)\",\"path\":\"${PATH}\"}"

# Wait for VM to show up in qm list (script starts seconds after boot_command).
VMID=""
elapsed=0
while [ "$elapsed" -lt 300 ]; do
  VMID="$(qm_cmd list 2>/dev/null | awk -v n="$VM_NAME" 'index($0, n) {print $1; exit}' || true)"
  if [ -n "$VMID" ]; then
    break
  fi
  sleep "$POLL_SEC"
  elapsed=$((elapsed + POLL_SEC))
done

if [ -z "$VMID" ]; then
  log_ndjson "H9" "vmid_not_found" "{\"vm_name\":\"${VM_NAME}\",\"waited\":${elapsed},\"qm_list_exit\":\"$(qm_cmd list >/tmp/qm-list.out 2>/tmp/qm-list.err; echo $?; tr '\n' ' ' </tmp/qm-list.err | cut -c1-120)\"}"
  echo "ERROR: no VM named ${VM_NAME} after ${elapsed}s (qm access?)" >&2
  qm_cmd list >&2 || true
  exit 1
fi
log_ndjson "H7" "vmid_resolved" "{\"vmid\":\"${VMID}\"}"

MAC=""
elapsed=0
while [ "$elapsed" -lt 120 ]; do
  MAC="$(qm_cmd config "$VMID" 2>/dev/null | sed -n 's/^net0:.*mac=\([0-9A-Fa-f:]*\).*/\1/pi' | head -1 || true)"
  if [ -n "$MAC" ]; then
    break
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done
if [ -z "$MAC" ]; then
  log_ndjson "H9" "mac_not_found" "{\"vmid\":\"${VMID}\"}"
  echo "ERROR: no net0 mac on VM ${VMID}" >&2
  qm_cmd config "$VMID" >&2 || true
  exit 1
fi
log_ndjson "H4" "mac_resolved" "{\"mac\":\"${MAC}\"}"

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
  ip neigh show 2>/dev/null | grep -i "$mac_l" | awk '{print $1}' | head -1 || true
}

ssh_ok() {
  local ip="$1"
  command -v sshpass >/dev/null 2>&1 || return 1
  sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 -o BatchMode=no \
    "${SSH_USER}@${ip}" 'echo ok' >/dev/null 2>&1
}

IP=""
elapsed=0
log_ndjson "H4" "wait_dhcp_ssh_begin" "{\"max\":${MAX_WAIT_SEC}}"
while [ "$elapsed" -lt "$MAX_WAIT_SEC" ]; do
  IP="$(find_ip || true)"
  if [ -n "$IP" ] && ssh_ok "$IP"; then
    break
  fi
  if [ $((elapsed % 120)) -eq 0 ]; then
    log_ndjson "H4" "wait_dhcp_ssh_poll" "{\"elapsed\":${elapsed},\"ip\":\"${IP:-none}\",\"agent\":\"$(qm_cmd agent "$VMID" ping >/dev/null 2>&1 && echo ok || echo no)\"}"
  fi
  sleep "$POLL_SEC"
  elapsed=$((elapsed + POLL_SEC))
  IP=""
done

if [ -z "$IP" ]; then
  log_ndjson "H4" "dhcp_ip_timeout" "{\"mac\":\"${MAC}\",\"waited\":${elapsed}}"
  echo "ERROR: timed out waiting for DHCP/SSH for MAC ${MAC}" >&2
  exit 1
fi
log_ndjson "H4" "ssh_ready" "{\"ip\":\"${IP}\",\"waited\":${elapsed}}"

if ! command -v sshpass >/dev/null 2>&1; then
  log_ndjson "H9" "sshpass_missing" "{}"
  echo "ERROR: sshpass required on Packer host" >&2
  exit 1
fi

# Best-effort guest agent + strip so-setup before playbook
sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "${SSH_USER}@${IP}" "echo '${SSH_PASS}' | sudo -S bash -c '
    dnf install -y qemu-guest-agent 2>/dev/null || yum install -y qemu-guest-agent 2>/dev/null || true
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
export ANSIBLE_LOCAL_TEMP="${ANSIBLE_HOME}/tmp"
mkdir -p "${ANSIBLE_HOME}/tmp" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK_PATH="$PLAYBOOK"
if [ ! -f "$PLAYBOOK_PATH" ] && [ -f "${SCRIPT_DIR}/../${PLAYBOOK}" ]; then
  PLAYBOOK_PATH="${SCRIPT_DIR}/../${PLAYBOOK}"
fi
if [ ! -f "$PLAYBOOK_PATH" ]; then
  log_ndjson "H9" "playbook_missing" "{\"playbook\":\"${PLAYBOOK}\"}"
  echo "ERROR: playbook not found: ${PLAYBOOK}" >&2
  rm -f "$INV"
  exit 1
fi

log_ndjson "H5" "ansible_start" "{\"ip\":\"${IP}\",\"playbook\":\"${PLAYBOOK_PATH}\"}"
set +e
ansible-playbook -i "$INV" "$PLAYBOOK_PATH"
RC=$?
set -e
rm -f "$INV"
log_ndjson "H5" "ansible_finished" "{\"ip\":\"${IP}\",\"rc\":${RC}}"
exit "$RC"

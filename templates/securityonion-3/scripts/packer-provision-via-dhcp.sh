#!/bin/bash
# Packer shell-local — Ludus user, no qm/sudo. Fixed MAC → dnsmasq lease → SSH.
set -u

VM_NAME="${VM_NAME:-securityonion-3-x64-template}"
SSH_USER="${SSH_USER:-onion}"
SSH_PASS="${SSH_PASS:-onion}"
PLAYBOOK="${PLAYBOOK:-ansible/reset-ssh-host-keys.yml}"
ANSIBLE_HOME="${ANSIBLE_HOME:-}"
MAX_WAIT_SEC="${MAX_WAIT_SEC:-7200}"
POLL_SEC=15
EXPECT_MAC="${EXPECT_MAC:-BC:24:11:50:03:01}"

ts() { date +%s%3N 2>/dev/null || echo "$(date +%s)000"; }
log_ndjson() {
  printf '%s\n' "{\"sessionId\":\"d940ab\",\"runId\":\"post-fix\",\"hypothesisId\":\"$1\",\"location\":\"packer-provision-via-dhcp.sh\",\"message\":\"$2\",\"data\":$3,\"timestamp\":$(ts)}"
}

log_ndjson "H7" "provision_script_start" "{\"vm_name\":\"${VM_NAME}\",\"whoami\":\"$(whoami 2>/dev/null || echo unknown)\",\"expect_mac\":\"${EXPECT_MAC}\"}"

find_ip() {
  local mac_l f line ip
  mac_l="$(echo "$EXPECT_MAC" | tr 'A-F' 'a-f')"
  for f in \
    /var/lib/misc/dnsmasq.leases \
    /var/lib/dnsmasq/dnsmasq.leases \
    /var/lib/ludus/dnsmasq.leases \
    /opt/ludus/resources/dnsmasq/leases \
    /opt/ludus/dnsmasq.leases
  do
    [ -r "$f" ] || continue
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
    -o ConnectTimeout=5 "${SSH_USER}@${ip}" 'echo ok' >/dev/null 2>&1
}

IP=""
elapsed=0
log_ndjson "H4" "wait_dhcp_ssh_begin" "{\"max\":${MAX_WAIT_SEC},\"mac\":\"${EXPECT_MAC}\"}"
while [ "$elapsed" -lt "$MAX_WAIT_SEC" ]; do
  IP="$(find_ip || true)"
  if [ -n "$IP" ] && ssh_ok "$IP"; then
    break
  fi
  if [ $((elapsed % 120)) -eq 0 ]; then
    readable="none"
    for f in /var/lib/misc/dnsmasq.leases /var/lib/dnsmasq/dnsmasq.leases /var/lib/ludus/dnsmasq.leases; do
      [ -r "$f" ] && readable="$f" && break
    done
    log_ndjson "H4" "wait_dhcp_ssh_poll" "{\"elapsed\":${elapsed},\"ip\":\"${IP:-none}\",\"lease_file\":\"${readable}\"}"
  fi
  sleep "$POLL_SEC"
  elapsed=$((elapsed + POLL_SEC))
  IP=""
done

if [ -z "$IP" ]; then
  log_ndjson "H4" "dhcp_ip_timeout" "{\"mac\":\"${EXPECT_MAC}\",\"waited\":${elapsed}}"
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
if [ -n "${ANSIBLE_HOME}" ]; then
  export ANSIBLE_HOME
  mkdir -p "${ANSIBLE_HOME}/tmp" 2>/dev/null || true
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK_PATH="$PLAYBOOK"
[ -f "$PLAYBOOK_PATH" ] || PLAYBOOK_PATH="${SCRIPT_DIR}/../ansible/reset-ssh-host-keys.yml"

log_ndjson "H5" "ansible_start" "{\"ip\":\"${IP}\"}"
set +e
ansible-playbook -i "$INV" "$PLAYBOOK_PATH"
RC=$?
rm -f "$INV"
log_ndjson "H5" "ansible_finished" "{\"rc\":${RC}}"
exit "$RC"

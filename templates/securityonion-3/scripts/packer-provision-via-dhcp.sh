#!/bin/bash
# Packer shell-local — runs as the Ludus *user* (not root). No qm/sudo.
# Discovers VM IP via dnsmasq lease for a fixed MAC set in the Packer HCL.
set -u

VM_NAME="${VM_NAME:-securityonion-3-x64-template}"
SSH_USER="${SSH_USER:-onion}"
SSH_PASS="${SSH_PASS:-onion}"
PLAYBOOK="${PLAYBOOK:-ansible/reset-ssh-host-keys.yml}"
ANSIBLE_HOME="${ANSIBLE_HOME:-}"
MAX_WAIT_SEC="${MAX_WAIT_SEC:-3600}"
POLL_SEC=15
# Must match network_adapters.mac_address in securityonion-3.pkr.hcl
EXPECT_MAC="${EXPECT_MAC:-BC:24:11:50:03:01}"

ts() { date +%s%3N 2>/dev/null || echo "$(date +%s)000"; }
log_ndjson() {
  # #region agent log
  printf '%s\n' "{\"sessionId\":\"d940ab\",\"runId\":\"post-fix\",\"hypothesisId\":\"$1\",\"location\":\"packer-provision-via-dhcp.sh\",\"message\":\"$2\",\"data\":$3,\"timestamp\":$(ts)}"
  # #endregion
}

log_ndjson "H7" "provision_script_start" "{\"vm_name\":\"${VM_NAME}\",\"whoami\":\"$(whoami 2>/dev/null || echo unknown)\",\"expect_mac\":\"${EXPECT_MAC}\"}"

lease_files() {
  printf '%s\n' \
    /var/lib/misc/dnsmasq.leases \
    /var/lib/dnsmasq/dnsmasq.leases \
    /var/lib/ludus/dnsmasq.leases \
    /opt/ludus/resources/dnsmasq/leases \
    /opt/ludus/dnsmasq.leases
}

find_ip() {
  local mac_l mac_bare f line ip
  mac_l="$(echo "$EXPECT_MAC" | tr 'A-F' 'a-f')"
  mac_bare="$(echo "$mac_l" | tr -d ':')"
  while IFS= read -r f; do
    [ -r "$f" ] || continue
    line="$(grep -iE "$mac_l|$mac_bare" "$f" 2>/dev/null | tail -1 || true)"
    [ -n "$line" ] || continue
    # dnsmasq: <expiry> <mac> <ip> <hostname> <client-id>
    ip="$(echo "$line" | awk '{print $3}')"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done < <(lease_files)
  # arp/neigh as unprivileged fallback
  ip neigh show 2>/dev/null | grep -iE "$mac_l|$mac_bare" | awk '{print $1}' | head -1 || true
}

# H20/H21: lease file diagnostics (no secrets)
lease_diag() {
  local mac_l mac_bare f count hit sample
  mac_l="$(echo "$EXPECT_MAC" | tr 'A-F' 'a-f')"
  mac_bare="$(echo "$mac_l" | tr -d ':')"
  f="none"
  count=0
  hit="no"
  sample=""
  while IFS= read -r candidate; do
    [ -r "$candidate" ] || continue
    f="$candidate"
    count="$(wc -l <"$candidate" 2>/dev/null | tr -d ' ' || echo 0)"
    if grep -iqE "$mac_l|$mac_bare" "$candidate" 2>/dev/null; then
      hit="yes"
      sample="$(grep -iE "$mac_l|$mac_bare" "$candidate" 2>/dev/null | tail -1 | awk '{print $2" "$3" "$4}')"
    else
      # first 5 macs only (field 2)
      sample="$(awk '{print $2}' "$candidate" 2>/dev/null | head -5 | tr '\n' ',' | sed 's/,$//')"
    fi
    break
  done < <(lease_files)
  printf '{"lease_file":"%s","lease_count":%s,"mac_hit":"%s","sample":"%s"}' \
    "$f" "${count:-0}" "$hit" "$sample"
}

ssh_ok() {
  local ip="$1"
  command -v sshpass >/dev/null 2>&1 || return 1
  sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 "${SSH_USER}@${ip}" 'echo ok' >/dev/null 2>&1
}

IP=""
elapsed=0
log_ndjson "H4" "wait_dhcp_ssh_begin" "{\"max\":${MAX_WAIT_SEC},\"mac\":\"${EXPECT_MAC}\",\"diag\":$(lease_diag)}"
while [ "$elapsed" -lt "$MAX_WAIT_SEC" ]; do
  IP="$(find_ip || true)"
  if [ -n "$IP" ]; then
    if ssh_ok "$IP"; then
      break
    fi
    # #region agent log
    if [ $((elapsed % 120)) -eq 0 ]; then
      log_ndjson "H22" "dhcp_ip_ssh_fail" "{\"elapsed\":${elapsed},\"ip\":\"${IP}\",\"diag\":$(lease_diag)}"
    fi
    # #endregion
  else
    # #region agent log
    if [ $((elapsed % 120)) -eq 0 ]; then
      log_ndjson "H18" "wait_dhcp_ssh_poll" "{\"elapsed\":${elapsed},\"ip\":\"none\",\"diag\":$(lease_diag)}"
    fi
    # #endregion
  fi
  sleep "$POLL_SEC"
  elapsed=$((elapsed + POLL_SEC))
  IP=""
done

if [ -z "${IP:-}" ]; then
  # final attempt
  IP="$(find_ip || true)"
fi
if [ -z "${IP:-}" ] || ! ssh_ok "$IP"; then
  log_ndjson "H4" "dhcp_ip_timeout" "{\"mac\":\"${EXPECT_MAC}\",\"waited\":${elapsed},\"last_ip\":\"${IP:-none}\",\"diag\":$(lease_diag)}"
  echo "ERROR: timed out waiting for DHCP/SSH for MAC ${EXPECT_MAC}" >&2
  echo "HINT: confirm lease file is readable by $(whoami), MAC matches Packer HCL, boot=order=scsi0;ide0 so disk boots after install." >&2
  exit 1
fi
log_ndjson "H4" "ssh_ready" "{\"ip\":\"${IP}\",\"waited\":${elapsed}}"

if ! command -v sshpass >/dev/null 2>&1; then
  log_ndjson "H9" "sshpass_missing" "{}"
  echo "ERROR: sshpass required for Ludus user Packer host" >&2
  exit 1
fi

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
if [ -n "${ANSIBLE_HOME}" ]; then
  export ANSIBLE_HOME
  export ANSIBLE_LOCAL_TEMP="${ANSIBLE_HOME}/tmp"
  mkdir -p "${ANSIBLE_HOME}/tmp" 2>/dev/null || true
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK_PATH="$PLAYBOOK"
if [ ! -f "$PLAYBOOK_PATH" ] && [ -f "${SCRIPT_DIR}/../ansible/reset-ssh-host-keys.yml" ]; then
  PLAYBOOK_PATH="${SCRIPT_DIR}/../ansible/reset-ssh-host-keys.yml"
fi
if [ ! -f "$PLAYBOOK_PATH" ]; then
  log_ndjson "H9" "playbook_missing" "{\"playbook\":\"${PLAYBOOK}\"}"
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

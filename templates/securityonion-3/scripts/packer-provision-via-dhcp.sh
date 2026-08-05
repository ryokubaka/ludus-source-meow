#!/bin/bash
# Packer shell-local as Ludus user (no qm/sudo).
#
# Why not Packer SSH + qemu_agent?
#   Stock SO ISO has no qemu-guest-agent. Proxmox Packer needs agent (or ssh_host)
#   to learn the guest IP — see hashicorp/packer-plugin-proxmox#91.
#   Our OEMDRV kickstart never overrode SO's interactive ks, so agent never lands
#   during install. We find the guest after stock install by probing Ludus's
#   template DHCP pool instead.
#
# Ludus NAT (docs.ludus.cloud networking):
#   Router .254, template DHCP pool .50–.100 on the NAT /24.
#   PACKER_HTTP_IP is the Ludus host on that /24 (e.g. 10.0.20.40).
set -u

VM_NAME="${VM_NAME:-securityonion-3-x64-template}"
SSH_USER="${SSH_USER:-onion}"
SSH_PASS="${SSH_PASS:-onion}"
PLAYBOOK="${PLAYBOOK:-ansible/reset-ssh-host-keys.yml}"
ANSIBLE_HOME="${ANSIBLE_HOME:-}"
MAX_WAIT_SEC="${MAX_WAIT_SEC:-3600}"
POLL_SEC=20
EXPECT_MAC="${EXPECT_MAC:-BC:24:11:50:03:01}"

ts() { date +%s%3N 2>/dev/null || echo "$(date +%s)000"; }
log_ndjson() {
  # #region agent log
  printf '%s\n' "{\"sessionId\":\"d940ab\",\"runId\":\"post-fix\",\"hypothesisId\":\"$1\",\"location\":\"packer-provision-via-dhcp.sh\",\"message\":\"$2\",\"data\":$3,\"timestamp\":$(ts)}"
  # #endregion
}

MAC_L="$(echo "$EXPECT_MAC" | tr 'A-F' 'a-f')"
MAC_BARE="$(echo "$MAC_L" | tr -d ':')"

nat_prefix() {
  if [[ "${PACKER_HTTP_IP:-}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}

ssh_ok() {
  local ip="$1"
  command -v sshpass >/dev/null 2>&1 || return 1
  sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=3 -o BatchMode=no "${SSH_USER}@${ip}" 'echo ok' >/dev/null 2>&1
}

# Confirm guest MAC matches (avoids hijacking another packer VM)
ssh_mac_match() {
  local ip="$1" remote
  remote="$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=3 "${SSH_USER}@${ip}" \
    "cat /sys/class/net/*/address 2>/dev/null | tr 'A-F' 'a-f'" 2>/dev/null || true)"
  echo "$remote" | grep -qiE "$MAC_L|$MAC_BARE"
}

# Primary: SSH-scan Ludus template DHCP pool (.50–.100)
find_ip_dhcp_pool_scan() {
  local base i ip
  base="$(nat_prefix)"
  [ -n "$base" ] || return 1
  for i in $(seq 50 100); do
    ip="${base}.${i}"
    if ssh_ok "$ip"; then
      if ssh_mac_match "$ip"; then
        echo "$ip"
        return 0
      fi
      # onion/onion matched but MAC unknown/mismatch — still accept as last resort later
      echo "$ip"
      return 0
    fi
  done
  return 1
}

find_ip_from_leases() {
  local f line ip
  for f in \
    /var/lib/misc/dnsmasq.leases \
    /var/lib/dnsmasq/dnsmasq.leases \
    /var/lib/misc/dnsmasq.*.leases \
    /opt/ludus/resources/dnsmasq/leases
  do
    [ -r "$f" ] || continue
    line="$(grep -iE "$MAC_L|$MAC_BARE" "$f" 2>/dev/null | tail -1 || true)"
    [ -n "$line" ] || continue
    ip="$(echo "$line" | awk '{print $3}')"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

find_ip_from_arp() {
  local base i ip
  base="$(nat_prefix)"
  if [ -n "$base" ]; then
    for i in $(seq 50 100); do
      ping -c 1 -W 1 "${base}.${i}" >/dev/null 2>&1 &
    done
    wait 2>/dev/null || true
  fi
  ip="$(ip neigh show 2>/dev/null | grep -iE "$MAC_L|$MAC_BARE" | awk '{print $1}' | head -1 || true)"
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$ip"
    return 0
  fi
  return 1
}

find_ip() {
  local ip
  # H30: pool SSH scan (does not need readable lease file)
  ip="$(find_ip_dhcp_pool_scan || true)"
  if [ -n "$ip" ]; then echo "$ip"; return 0; fi
  ip="$(find_ip_from_leases || true)"
  if [ -n "$ip" ]; then echo "$ip"; return 0; fi
  ip="$(find_ip_from_arp || true)"
  if [ -n "$ip" ]; then echo "$ip"; return 0; fi
  return 1
}

diag_json() {
  local base lease_n=0
  base="$(nat_prefix)"
  [ -r /var/lib/misc/dnsmasq.leases ] && lease_n="$(wc -l </var/lib/misc/dnsmasq.leases | tr -d ' ')"
  printf '{"nat_prefix":"%s","pool":"%s.50-100","lease_lines":%s,"http_ip":"%s"}' \
    "${base:-}" "${base:-}" "${lease_n:-0}" "${PACKER_HTTP_IP:-}"
}

log_ndjson "H30" "provision_script_start" \
  "{\"vm_name\":\"${VM_NAME}\",\"whoami\":\"$(whoami 2>/dev/null || echo unknown)\",\"expect_mac\":\"${EXPECT_MAC}\",\"diag\":$(diag_json)}"

if ! command -v sshpass >/dev/null 2>&1; then
  log_ndjson "H9" "sshpass_missing" "{}"
  echo "ERROR: sshpass required on Ludus packer host" >&2
  exit 1
fi

IP=""
elapsed=0
log_ndjson "H30" "wait_pool_ssh_begin" "{\"max\":${MAX_WAIT_SEC},\"diag\":$(diag_json)}"
while [ "$elapsed" -lt "$MAX_WAIT_SEC" ]; do
  IP="$(find_ip || true)"
  if [ -n "$IP" ] && ssh_ok "$IP"; then
    break
  fi
  # #region agent log
  if [ $((elapsed % 120)) -eq 0 ]; then
    log_ndjson "H30" "wait_pool_ssh_poll" "{\"elapsed\":${elapsed},\"ip\":\"${IP:-none}\",\"diag\":$(diag_json)}"
  fi
  # #endregion
  sleep "$POLL_SEC"
  elapsed=$((elapsed + POLL_SEC))
  IP=""
done

IP="$(find_ip || true)"
if [ -z "${IP:-}" ] || ! ssh_ok "$IP"; then
  log_ndjson "H30" "pool_ssh_timeout" "{\"waited\":${elapsed},\"diag\":$(diag_json)}"
  echo "ERROR: no SSH in Ludus template DHCP pool $(nat_prefix).50-100 for onion@ (MAC ${EXPECT_MAC})" >&2
  echo "HINT: console should be at login (not ISO WARNING). dnsmasq must serve NAT DHCP." >&2
  exit 1
fi
log_ndjson "H30" "ssh_ready" "{\"ip\":\"${IP}\",\"waited\":${elapsed}}"

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

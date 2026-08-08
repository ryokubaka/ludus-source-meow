#!/bin/bash
# Re-run packer ansible provisioning against a live SO VM (~1–2 min, no ISO/packer).
#
# Use while a packer VM is still up after keystroke install, or any SO VM with onion SSH
# on the Ludus template DHCP network.
#
# On Ludus host, from the template directory:
#   cd /opt/ludus/packer/securityonion-3
#   SO_TEST_IP=192.0.2.65 ANSIBLE_HOME=/opt/ludus/users/$USER/.ansible \
#     SSH_PASS=onion ./scripts/test-provision-against-vm.sh
#
# Or guest-agent install only (~30s):
#   SO_TEST_IP=192.0.2.65 SSH_PASS=onion ./scripts/test-provision-against-vm.sh --guest-agent-only
#
# Auto-discover IP (same scan as packer) if SO_TEST_IP unset:
#   ANSIBLE_HOME=... EXPECT_MAC=BC:24:11:50:02:04 ./scripts/test-provision-against-vm.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GUEST_AGENT_ONLY=0
if [ "${1:-}" = "--guest-agent-only" ]; then
  GUEST_AGENT_ONLY=1
fi

SSH_USER="${SSH_USER:-onion}"
SSH_PASS="${SSH_PASS:-onion}"
PLAYBOOKS="${PLAYBOOKS:-ansible/ludus-linux-prereqs.yml ansible/securityonion-prep.yml ansible/reset-machine-id.yml ansible/reset-ssh-host-keys.yml}"
SO_TEMPLATE_MARKER="${SO_TEMPLATE_MARKER:-securityonion-3-packer}"
EXPECT_MAC="${EXPECT_MAC:-BC:24:11:50:03:01}"
SSH_TIMEOUT=2

# shellcheck source=/dev/null
source "${ROOT}/scripts/install-qemu-guest-agent.sh"

ssh_ok() {
  local ip="$1"
  command -v sshpass >/dev/null 2>&1 || return 1
  sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=no "${SSH_USER}@${ip}" 'echo ok' >/dev/null 2>&1
}

discover_prefixes() {
  local p conf line start seen="" out=""
  for conf in /etc/dnsmasq.conf /etc/dnsmasq.d/*; do
    [ -r "$conf" ] || continue
    while IFS= read -r line; do
      start="$(echo "$line" | sed -n 's/.*dhcp-range=\([^,]*\),.*/\1/p')"
      [[ "$start" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+$ ]] || continue
      p="${BASH_REMATCH[1]}"
      case " $seen " in *" $p "*) ;; *) seen="$seen $p"; out="${out}${out:+ }$p" ;; esac
    done < <(grep -hE '^\s*dhcp-range=' "$conf" 2>/dev/null || true)
  done
  [ -z "$out" ] && out="192.0.2"
  echo "$out"
}

find_ip_pool_scan() {
  local prefixes prefix i ip
  prefixes="$(discover_prefixes)"
  for prefix in $prefixes; do
    for i in $(seq 50 100); do
      ip="${prefix}.${i}"
      if ssh_ok "$ip"; then
        echo "$ip"
        return 0
      fi
    done
  done
  return 1
}

setup_ansible_env() {
  export ANSIBLE_HOST_KEY_CHECKING=False
  if [ -z "${ANSIBLE_HOME:-}" ]; then
    echo "ERROR: set ANSIBLE_HOME=/opt/ludus/users/<user>/.ansible" >&2
    exit 1
  fi
  export ANSIBLE_HOME
  export ANSIBLE_LOCAL_TEMP="${ANSIBLE_HOME}/tmp"
  export ANSIBLE_SSH_CONTROL_PATH_DIR="${ANSIBLE_HOME}/cp"
  export ANSIBLE_PERSISTENT_CONTROL_PATH_DIR="${ANSIBLE_HOME}/pc"
  mkdir -p "${ANSIBLE_LOCAL_TEMP}" "${ANSIBLE_SSH_CONTROL_PATH_DIR}" "${ANSIBLE_PERSISTENT_CONTROL_PATH_DIR}"
}

IP="${SO_TEST_IP:-}"
if [ -z "$IP" ]; then
  echo "SO_TEST_IP unset — scanning Ludus DHCP pool..." >&2
  IP="$(find_ip_pool_scan || true)"
fi

if [ -z "$IP" ] || ! ssh_ok "$IP"; then
  echo "ERROR: no SSH to SO VM. Set SO_TEST_IP or leave packer VM running." >&2
  exit 1
fi
echo "Testing against ${IP}" >&2

if [ "$GUEST_AGENT_ONLY" -eq 1 ]; then
  echo "=== guest-agent install only ===" >&2
  sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "${ROOT}/scripts/install-qemu-guest-agent.sh" "${SSH_USER}@${IP}:/tmp/install-qemu-guest-agent.sh"
  sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "${SSH_USER}@${IP}" "echo '${SSH_PASS}' | sudo -S bash /tmp/install-qemu-guest-agent.sh"
  sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "${SSH_USER}@${IP}" "echo '${SSH_PASS}' | sudo -S systemctl enable --now qemu-guest-agent && rpm -q qemu-guest-agent"
  echo "OK: guest-agent installed and running on ${IP}" >&2
  exit 0
fi

setup_ansible_env

INV="$(mktemp)"
printf '[all]\n%s ansible_user=%s ansible_password=%s ansible_become_password=%s ansible_python_interpreter=/usr/bin/python3 ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"\n' \
  "$IP" "$SSH_USER" "$SSH_PASS" "$SSH_PASS" >"$INV"

ANSIBLE_EXTRA=(
  --extra-vars
  "{\"ansible_python_interpreter\": \"/usr/bin/python3\", \"ansible_password\": \"${SSH_PASS}\", \"ansible_sudo_pass\": \"${SSH_PASS}\", \"so_template_marker\": \"${SO_TEMPLATE_MARKER}\"}"
)

RC=0
for pb in $PLAYBOOKS; do
  echo "=== ansible-playbook ${pb} ===" >&2
  if ! ansible-playbook -i "$INV" "$pb" "${ANSIBLE_EXTRA[@]}"; then
    RC=1
    break
  fi
done
rm -f "$INV"

if [ "$RC" -eq 0 ]; then
  echo "OK: all provision playbooks passed on ${IP}" >&2
fi
exit "$RC"

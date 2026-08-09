# Shared helpers for ludus-source-meow automated tests (source on Ludus host).
# shellcheck shell=bash

ludus_test_repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

ludus_test_defaults() {
  REPO_ROOT="${REPO_ROOT:-$(ludus_test_repo_root)}"
  LUDUS_HOST="${LUDUS_HOST:-10.0.20.40}"
  LUDUS_SSH_KEY="${LUDUS_SSH_KEY:-/tmp/ludus_root_key}"
  LUDUS_USER="${LUDUS_USER:-catshadowstep}"
  LUDUS_INSTALL_ROOT="${LUDUS_INSTALL_ROOT:-/opt/ludus}"
  SOURCE_ID="${SOURCE_ID:-catshadowstep-ryokubaka-ludus-source-meow}"
}

ludus_test_ensure_key() {
  if [ -r "${LUDUS_SSH_KEY}" ]; then
    return 0
  fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx ludus-ux; then
    docker cp ludus-ux:/app/ssh/id_rsa "${LUDUS_SSH_KEY}"
    chmod 600 "${LUDUS_SSH_KEY}"
    return 0
  fi
  echo "ERROR: ${LUDUS_SSH_KEY} missing and ludus-ux container not running" >&2
  return 1
}

ludus_test_ssh() {
  ssh -i "${LUDUS_SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=15 "root@${LUDUS_HOST}" "$@"
}

ludus_test_user_api_key() {
  ludus_test_ssh "grep -m1 LUDUS_API_KEY /home/${LUDUS_USER}/.bashrc | cut -d= -f2- | tr -d \"'\""
}

ludus_test_as_user() {
  local api_key
  api_key="$(ludus_test_user_api_key)"
  ludus_test_ssh "runuser -u ${LUDUS_USER} -- env LUDUS_API_KEY='${api_key}' LUDUS_VERSION=2 ludus $*"
}

ludus_test_remote_source_dir() {
  echo "/tmp/ludus-source-meow-${LUDUS_USER}"
}

ludus_test_sync_source() {
  local remote_dir role_path short_name
  remote_dir="$(ludus_test_remote_source_dir)"
  short_name="ludus_securityonion"
  role_path="${LUDUS_INSTALL_ROOT}/users/${LUDUS_USER}/.ansible/roles/ryokubaka.ludus_securityonion"
  echo "=== syncing role → ${LUDUS_HOST}:${role_path} ===" >&2
  find "${REPO_ROOT}" -name '*.sh' -exec sed -i 's/\r$//' {} +
  ludus_test_ssh "install -d -o ${LUDUS_USER} -g ludus ${role_path}"
  rsync -az --delete \
    -e "ssh -i ${LUDUS_SSH_KEY} -o StrictHostKeyChecking=no" \
    "${REPO_ROOT}/ansible/roles/${short_name}/" "root@${LUDUS_HOST}:${role_path}/"
  ludus_test_ssh "chown -R ${LUDUS_USER}:ludus ${role_path}"
  # Also stash full repo on host for debugging
  rsync -az --delete \
    --exclude '.git' \
    -e "ssh -i ${LUDUS_SSH_KEY} -o StrictHostKeyChecking=no" \
    "${REPO_ROOT}/" "root@${LUDUS_HOST}:${remote_dir}/"
  ludus_test_ssh "chown -R ${LUDUS_USER}:ludus ${remote_dir}"
}

ludus_test_install_local_role() {
  local role="${1:?role name required}"
  local role_path="${LUDUS_INSTALL_ROOT}/users/${LUDUS_USER}/.ansible/roles/${role}"
  echo "=== verifying local role ${role} ===" >&2
  if ludus_test_ssh "test -f ${role_path}/tasks/main.yml"; then
    echo "Role OK: ${role_path}" >&2
    return 0
  fi
  echo "WARN: role missing after source update; copying from synced tree" >&2
  local remote_dir short_name
  remote_dir="$(ludus_test_remote_source_dir)"
  short_name="${role##*.}"
  ludus_test_ssh "install -d -o ${LUDUS_USER} -g ludus ${role_path} && rsync -a --delete ${remote_dir}/ansible/roles/${short_name}/ ${role_path}/"
  ludus_test_ssh "test -f ${role_path}/tasks/main.yml"
}

ludus_test_range_state() {
  local range_id="${1:?range id}"
  ludus_test_as_user range status 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -oE 'ABORTED|SUCCESS|DEPLOYING|FAILED|WAITING|NEVER DEPLOYED' \
    | head -1 \
    || true
}

ludus_test_range_config_path() {
  local range_id="${1:?range id}"
  echo "${LUDUS_INSTALL_ROOT}/ranges/${range_id}/range-config.yml"
}

ludus_test_ansible_log_path() {
  local range_id="${1:?range id}"
  echo "${LUDUS_INSTALL_ROOT}/ranges/${range_id}/ansible.log"
}

ludus_test_ansible_running() {
  ludus_test_ssh "pgrep -af 'python3.*ansible-playbook.*range-management/ludus.yml' 2>/dev/null | grep -v pgrep >/dev/null"
}

ludus_test_wait_deploy_idle() {
  local range_id="${1:?range id}" max_wait="${2:-600}" elapsed=0 state
  while [ "$elapsed" -lt "$max_wait" ]; do
    state="$(ludus_test_range_state "${range_id}")"
    if ! ludus_test_ansible_running; then
      case "${state}" in
        DEPLOYING|WAITING)
          sleep 10
          elapsed=$((elapsed + 10))
          continue
          ;;
        *) return 0 ;;
      esac
    fi
    case "${state}" in
      DEPLOYING|WAITING)
        echo "deploy in progress (state=${state}, ${elapsed}s) — waiting..." >&2
        ;;
      *)
        echo "cleaning stale ansible (state=${state})..." >&2
        ludus_test_as_user range abort -r "${range_id}" 2>/dev/null || true
        ludus_test_ssh "pkill -9 -f 'python3.*ansible-playbook.*range-management/ludus.yml' 2>/dev/null || true"
        sleep 5
        return 0
        ;;
    esac
    sleep 10
    elapsed=$((elapsed + 10))
  done
  echo "ERROR: deploy still active (state=${state}) after ${max_wait}s — not aborting live deploy" >&2
  return 1
}

ludus_test_so_proxmox_vmid() {
  local vm_name="${1:?vm name}"
  ludus_test_ssh "qm list | awk -v n='${vm_name}' '\$2==n {print \$1; exit}'"
}

ludus_test_ensure_so_reachable() {
  local ip="${1:?ip}" vm_name="${2:?vm name}" vmid attempts=0 max_attempts=3
  while [ "$attempts" -lt "$max_attempts" ]; do
    if ludus_test_ssh "ping -c1 -W3 '${ip}' >/dev/null 2>&1 && timeout 12 sshpass -p '${SO_SSH_PASS:-onion}' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 '${SO_SSH_USER:-onion}@${ip}' true >/dev/null 2>&1"; then
      return 0
    fi
    attempts=$((attempts + 1))
    vmid="$(ludus_test_so_proxmox_vmid "${vm_name}" 2>/dev/null || true)"
    echo "SO VM unreachable at ${ip} — reboot attempt ${attempts}/${max_attempts} (vmid=${vmid:-unknown})" >&2
    if [ -n "${vmid}" ]; then
      ludus_test_ssh "qm reboot '${vmid}' 2>/dev/null || qm reset '${vmid}' 2>/dev/null || true"
      sleep 90
    else
      sleep 30
    fi
  done
  return 1
}

ludus_test_cleanup_so_vm() {
  local vm_name="${1:?vm name}" ip="${2:?ip}"
  ludus_test_ssh "timeout 90 sshpass -p '${SO_SSH_PASS:-onion}' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 '${SO_SSH_USER:-onion}@${ip}' bash -s" <<'CLEANUP' || true
set -euo pipefail
sudo pkill -f '[s]o-setup' 2>/dev/null || true
sudo pkill -f '/usr/local/sbin/ludus-dns-keeper' 2>/dev/null || true
sudo chattr -i /etc/resolv.conf 2>/dev/null || true
sudo rm -f /var/run/ludus-dns-keeper.pid /var/run/ludus-so-setup.pid
while IFS= read -r con; do
  [[ -z "$con" ]] && continue
  sudo nmcli con down "$con" 2>/dev/null || true
  sudo nmcli con delete "$con" 2>/dev/null || true
done < <(nmcli -t -f NAME con show 2>/dev/null | grep -Ei 'bond|bonding_masters' || true)
if ip link show bond0 &>/dev/null; then
  sudo nmcli dev disconnect bond0 2>/dev/null || true
  sudo ip link set bond0 down 2>/dev/null || true
  sudo ip link delete bond0 2>/dev/null || true
fi
if [[ -f /sys/class/net/bonding_masters ]]; then
  while read -r master; do
    [[ -z "$master" ]] && continue
    sudo ip link set "$master" down 2>/dev/null || true
    echo "-${master}" | sudo tee /sys/class/net/bonding_masters >/dev/null 2>&1 || true
  done < /sys/class/net/bonding_masters
fi
# Sniff NIC must not hold DHCP / default route into next so-setup.
if nmcli -t -f DEVICE,NAME con show 2>/dev/null | awk -F: '$1=="ens19"{print $2}' | head -1 | grep -q .; then
  sn_con=$(nmcli -t -f DEVICE,NAME con show | awk -F: '$1=="ens19"{print $2; exit}')
  sudo nmcli con mod "$sn_con" ipv4.method disabled ipv6.method ignore ipv4.dns "" 2>/dev/null || true
  sudo nmcli con up "$sn_con" 2>/dev/null || true
  sudo ip -4 addr flush dev ens19 scope global 2>/dev/null || true
fi
sudo rm -f /etc/ludus-so-setup-complete /var/log/ludus-so-setup.log
# Stale salt-master after aborted/reinstall leaves empty PKI → salt-call auth timeout.
# Stop services and wipe PKI so next so-setup regenerates master/minion keys cleanly.
sudo systemctl stop salt-minion salt-master 2>/dev/null || true
sudo pkill -9 -f '/usr/bin/salt-(master|minion)' 2>/dev/null || true
sudo rm -rf /etc/salt/pki/master /etc/salt/pki/minion
sudo mkdir -p /etc/salt/pki/master /etc/salt/pki/minion
# Rotate stale sosetup so monitors do not report prior-run DNS/MNIC failures.
if [[ -f /root/sosetup.log ]]; then
  sudo mv /root/sosetup.log "/root/sosetup.log.cleanup-$(date -u +%Y%m%dT%H%M%S)" 2>/dev/null || \
    sudo rm -f /root/sosetup.log
fi
echo cleanup-done
CLEANUP
}

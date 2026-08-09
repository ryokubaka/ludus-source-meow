#!/bin/bash
# Ludus Security Onion packer provisioner (shell-local).
#
# Standard Ludus Linux templates use communicator=ssh + packer ansible provisioner.
# Stock SO ISO has no guest-agent during install (proxmox#91), so we SSH-scan the
# Ludus template DHCP pool (.50-.100) then run the same ansible playbooks BSL uses.
set -u

SCRIPT_VERSION="1.0.0"

VM_NAME="${VM_NAME:-securityonion-3-x64-template}"
SSH_USER="${SSH_USER:-onion}"
SSH_PASS="${SSH_PASS:-onion}"
PLAYBOOKS="${PLAYBOOKS:-ansible/ludus-linux-prereqs.yml ansible/securityonion-prep.yml ansible/reset-machine-id.yml ansible/reset-ssh-host-keys.yml}"
SO_TEMPLATE_MARKER="${SO_TEMPLATE_MARKER:-securityonion-3-packer}"
ANSIBLE_HOME="${ANSIBLE_HOME:-}"
MAX_WAIT_SEC="${MAX_WAIT_SEC:-3600}"
POLL_SEC=15
EXPECT_MAC="${EXPECT_MAC:-BC:24:11:50:03:01}"
SSH_TIMEOUT=2

echo "SO packer provision script ${SCRIPT_VERSION}" >&2

MAC_L="$(echo "$EXPECT_MAC" | tr 'A-F' 'a-f')"

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
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case " $seen " in *" $p "*) ;; *) seen="$seen $p"; out="${out}${out:+ }$p" ;; esac
  done < <(ip -4 -o addr show 2>/dev/null | awk '!/127\.0\.0\.|169\.254\./{split($4,a,"/"); split(a[1],b,"."); print b[1]"."b[2]"."b[3]}' | sort -u)
  if [[ "${PACKER_HTTP_IP:-}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
    p="${BASH_REMATCH[1]}"
    case " $seen " in *" $p "*) ;; *) out="${out}${out:+ }$p" ;; esac
  fi
  if [ -z "$out" ]; then
    out="192.0.2"
  fi
  echo "$out"
}

find_ip_pool_scan() {
  local prefixes prefix i ip tmp found=""
  prefixes="$(discover_prefixes)"
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2086
  for prefix in $prefixes; do
    for i in $(seq 50 100); do
      ip="${prefix}.${i}"
      (
        if ssh_ok "$ip"; then
          printf '%s\n' "$ip" >"${tmp}/${prefix}_${i}.ok"
        fi
      ) &
    done
  done
  wait 2>/dev/null || true
  found="$(ls "${tmp}"/*.ok 2>/dev/null | head -1 || true)"
  if [ -n "$found" ]; then
    cat "$found"
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"
  return 1
}

find_ip_from_leases() {
  local f line ip
  for f in /var/lib/misc/dnsmasq.leases /var/lib/dnsmasq/dnsmasq.leases /var/lib/misc/dnsmasq.*.leases; do
    [ -r "$f" ] || continue
    line="$(grep -i "$MAC_L" "$f" 2>/dev/null | tail -1 || true)"
    [ -n "$line" ] || continue
    ip="$(echo "$line" | awk '{print $3}')"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

find_ip() {
  local ip
  ip="$(find_ip_pool_scan || true)"
  [ -n "$ip" ] && { echo "$ip"; return 0; }
  ip="$(find_ip_from_leases || true)"
  [ -n "$ip" ] && { echo "$ip"; return 0; }
  return 1
}

if ! command -v sshpass >/dev/null 2>&1; then
  echo "ERROR: sshpass required on Ludus packer host" >&2
  exit 1
fi

IP=""
elapsed=0
while [ "$elapsed" -lt "$MAX_WAIT_SEC" ]; do
  IP="$(find_ip || true)"
  if [ -n "$IP" ] && ssh_ok "$IP"; then
    break
  fi
  sleep "$POLL_SEC"
  elapsed=$((elapsed + POLL_SEC))
  IP=""
done

IP="$(find_ip || true)"
if [ -z "${IP:-}" ] || ! ssh_ok "$IP"; then
  echo "ERROR: no ${SSH_USER} SSH in template DHCP pools. prefixes=$(discover_prefixes)" >&2
  exit 1
fi
echo "SSH ready at ${IP} (waited ${elapsed}s)" >&2

setup_ansible_env() {
  export ANSIBLE_HOST_KEY_CHECKING=False

  if [ -z "${ANSIBLE_HOME}" ]; then
    echo "ERROR: ANSIBLE_HOME unset — Ludus must pass var.ansible_home" >&2
    exit 1
  fi

  export ANSIBLE_HOME
  export ANSIBLE_LOCAL_TEMP="${ANSIBLE_HOME}/tmp"
  export ANSIBLE_SSH_CONTROL_PATH_DIR="${ANSIBLE_HOME}/cp"
  export ANSIBLE_PERSISTENT_CONTROL_PATH_DIR="${ANSIBLE_HOME}/pc"

  if ! mkdir -p "${ANSIBLE_LOCAL_TEMP}" "${ANSIBLE_SSH_CONTROL_PATH_DIR}" "${ANSIBLE_PERSISTENT_CONTROL_PATH_DIR}"; then
    echo "ERROR: cannot create Ansible dirs under ${ANSIBLE_HOME}" >&2
    exit 1
  fi

  if [ ! -w "${ANSIBLE_SSH_CONTROL_PATH_DIR}" ]; then
    echo "ERROR: ${ANSIBLE_SSH_CONTROL_PATH_DIR} not writable by $(whoami)" >&2
    exit 1
  fi
}
setup_ansible_env

INV="$(mktemp)"
printf '[all]\n%s ansible_user=%s ansible_password=%s ansible_become_password=%s ansible_python_interpreter=/usr/bin/python3 ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"\n' \
  "$IP" "$SSH_USER" "$SSH_PASS" "$SSH_PASS" >"$INV"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_EXTRA=(
  --extra-vars
  "{\"ansible_python_interpreter\": \"/usr/bin/python3\", \"ansible_password\": \"${SSH_PASS}\", \"ansible_sudo_pass\": \"${SSH_PASS}\", \"so_template_marker\": \"${SO_TEMPLATE_MARKER}\"}"
)

RC=0
# shellcheck disable=SC2086
for pb in $PLAYBOOKS; do
  PLAYBOOK_PATH="$pb"
  if [ ! -f "$PLAYBOOK_PATH" ] && [ -f "${SCRIPT_DIR}/../${pb}" ]; then
    PLAYBOOK_PATH="${SCRIPT_DIR}/../${pb}"
  fi
  if [ ! -f "$PLAYBOOK_PATH" ]; then
    echo "ERROR: playbook missing: ${pb}" >&2
    RC=1
    break
  fi
  echo "Running ansible-playbook ${PLAYBOOK_PATH} against ${IP}" >&2
  if ! ansible-playbook -i "$INV" "$PLAYBOOK_PATH" "${ANSIBLE_EXTRA[@]}"; then
    RC=1
    break
  fi
done

rm -f "$INV"
exit "$RC"

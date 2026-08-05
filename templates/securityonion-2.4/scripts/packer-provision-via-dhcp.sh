#!/bin/bash
# Packer shell-local as Ludus user (no qm/sudo).
#
# Stock SO has no qemu-guest-agent → Packer cannot learn IP (proxmox#91).
# Find guest by SSH-scanning Ludus template DHCP pool (.50–.100).
#
# H31: PACKER_HTTP_IP is NOT always the NAT /24 (often management).
#      Discover pools from dnsmasq dhcp-range= and host interface addrs.
#
# MUST be at: /opt/ludus/packer/securityonion-2.4/scripts/packer-provision-via-dhcp.sh
# (Packer log path — not users/*/packer or sources/*/templates)
set -u

SCRIPT_VERSION="H32-netup-20260805"

VM_NAME="${VM_NAME:-securityonion-2.4-x64-template}"
SSH_USER="${SSH_USER:-onion}"
SSH_PASS="${SSH_PASS:-onion}"
PLAYBOOK="${PLAYBOOK:-ansible/reset-ssh-host-keys.yml}"
ANSIBLE_HOME="${ANSIBLE_HOME:-}"
MAX_WAIT_SEC="${MAX_WAIT_SEC:-3600}"
POLL_SEC=15
EXPECT_MAC="${EXPECT_MAC:-BC:24:11:50:02:04}"
SSH_TIMEOUT=2

ts() { date +%s%3N 2>/dev/null || echo "$(date +%s)000"; }
log_ndjson() {
  # #region agent log
  printf '%s\n' "{\"sessionId\":\"d940ab\",\"runId\":\"post-fix\",\"hypothesisId\":\"$1\",\"location\":\"packer-provision-via-dhcp.sh\",\"message\":\"$2\",\"data\":$3,\"timestamp\":$(ts)}"
  # #endregion
}

# Fail loud if stale H30 script somehow still referenced
echo "SO packer provision script ${SCRIPT_VERSION}" >&2

MAC_L="$(echo "$EXPECT_MAC" | tr 'A-F' 'a-f')"

ssh_ok() {
  local ip="$1"
  command -v sshpass >/dev/null 2>&1 || return 1
  sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=no "${SSH_USER}@${ip}" 'echo ok' >/dev/null 2>&1
}

# Collect candidate /24 prefixes for Ludus template DHCP
discover_prefixes() {
  local p conf line start seen="" out=""
  # 1) dnsmasq dhcp-range=START,END,... → use START's /24
  for conf in /etc/dnsmasq.conf /etc/dnsmasq.d/*; do
    [ -r "$conf" ] || continue
    while IFS= read -r line; do
      start="$(echo "$line" | sed -n 's/.*dhcp-range=\([^,]*\),.*/\1/p')"
      [[ "$start" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+$ ]] || continue
      p="${BASH_REMATCH[1]}"
      case " $seen " in *" $p "*) ;; *) seen="$seen $p"; out="${out}${out:+ }$p" ;; esac
    done < <(grep -hE '^\s*dhcp-range=' "$conf" 2>/dev/null || true)
  done
  # 2) host IPv4s (skip loopback / link-local)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case " $seen " in *" $p "*) ;; *) seen="$seen $p"; out="${out}${out:+ }$p" ;; esac
  done < <(ip -4 -o addr show 2>/dev/null | awk '!/127\.0\.0\.|169\.254\./{split($4,a,"/"); split(a[1],b,"."); print b[1]"."b[2]"."b[3]}' | sort -u)
  # 3) PACKER_HTTP_IP last
  if [[ "${PACKER_HTTP_IP:-}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
    p="${BASH_REMATCH[1]}"
    case " $seen " in *" $p "*) ;; *) out="${out}${out:+ }$p" ;; esac
  fi
  # Ludus default TEST-NET if nothing found
  if [ -z "$out" ]; then
    out="192.0.2"
  fi
  echo "$out"
}

# Parallel SSH scan of .50–.100 on each prefix (~few seconds)
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

diag_json() {
  local prefixes lease_n=0 ranges=""
  prefixes="$(discover_prefixes | tr ' ' ',')"
  [ -r /var/lib/misc/dnsmasq.leases ] && lease_n="$(wc -l </var/lib/misc/dnsmasq.leases | tr -d ' ')"
  ranges="$(grep -hE '^\s*dhcp-range=' /etc/dnsmasq.conf /etc/dnsmasq.d/* 2>/dev/null | head -5 | tr '\n' ';' | sed 's/"//g')"
  printf '{"prefixes":"%s","dhcp_ranges":"%s","lease_lines":%s,"http_ip":"%s"}' \
    "$prefixes" "$ranges" "${lease_n:-0}" "${PACKER_HTTP_IP:-}"
}

log_ndjson "H31" "provision_script_start" \
  "{\"script_version\":\"${SCRIPT_VERSION}\",\"vm_name\":\"${VM_NAME}\",\"whoami\":\"$(whoami 2>/dev/null || echo unknown)\",\"expect_mac\":\"${EXPECT_MAC}\",\"diag\":$(diag_json)}"

if ! command -v sshpass >/dev/null 2>&1; then
  log_ndjson "H9" "sshpass_missing" "{}"
  echo "ERROR: sshpass required on Ludus packer host" >&2
  exit 1
fi

IP=""
elapsed=0
log_ndjson "H31" "wait_pool_ssh_begin" "{\"max\":${MAX_WAIT_SEC},\"diag\":$(diag_json)}"
while [ "$elapsed" -lt "$MAX_WAIT_SEC" ]; do
  # #region agent log
  log_ndjson "H31" "scan_start" "{\"elapsed\":${elapsed},\"diag\":$(diag_json)}"
  # #endregion
  IP="$(find_ip || true)"
  if [ -n "$IP" ] && ssh_ok "$IP"; then
    break
  fi
  # #region agent log
  log_ndjson "H31" "scan_miss" "{\"elapsed\":${elapsed},\"ip\":\"${IP:-none}\",\"diag\":$(diag_json)}"
  # #endregion
  sleep "$POLL_SEC"
  elapsed=$((elapsed + POLL_SEC))
  IP=""
done

IP="$(find_ip || true)"
if [ -z "${IP:-}" ] || ! ssh_ok "$IP"; then
  log_ndjson "H31" "pool_ssh_timeout" "{\"waited\":${elapsed},\"diag\":$(diag_json)}"
  echo "ERROR: no onion SSH in template DHCP pools. prefixes=$(discover_prefixes)" >&2
  echo "HINT: check console = login (not ISO). paste dhcp_ranges from logs." >&2
  exit 1
fi
log_ndjson "H31" "ssh_ready" "{\"ip\":\"${IP}\",\"waited\":${elapsed}}"

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

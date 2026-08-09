#!/bin/bash
# Automated ludus_securityonion role test on a live Ludus range (only-roles deploy).
#
# Runs sync → source install → optional VM cleanup → ludus range deploy (user-defined-roles
# + only-roles) → log monitor → post-checks. No manual watching required.
#
# Usage (from ludus-source-meow repo root):
#   ./scripts/test-role-deploy.sh full          # sync + install + deploy + verify
#   ./scripts/test-role-deploy.sh deploy        # deploy + monitor + verify (role already on host)
#   ./scripts/test-role-deploy.sh verify        # post-checks only
#   ./scripts/test-role-deploy.sh monitor       # tail active deploy log until done
#
# Env (defaults target catshadowstep + SO VM):
#   LUDUS_HOST=10.0.20.40
#   LUDUS_SSH_KEY=/tmp/ludus_root_key
#   LUDUS_USER=catshadowstep
#   LUDUS_RANGE=catshadowstep
#   SO_VM=catshadowstep-so
#   SO_ROLE=ryokubaka.ludus_securityonion
#   SO_VM_IP=10.1.10.20          # optional override
#   SOURCE_ID=meow
#   SO_SSH_USER=onion
#   SO_SSH_PASS=onion
#   DEPLOY_TIMEOUT_SEC=7200        # so-setup can run 30–90+ min
#   LOG_POLL_SEC=30
#   CLEANUP_BEFORE=1             # remove marker/bond0/stale so-setup on SO VM
#   FORCE_DEPLOY=1               # pass --force (testing mode)
#   SKIP_SOURCE_SYNC=0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ludus-test-common.sh
source "${SCRIPT_DIR}/lib/ludus-test-common.sh"

ludus_test_defaults

LUDUS_RANGE="${LUDUS_RANGE:-catshadowstep}"
SO_VM="${SO_VM:-catshadowstep-so}"
SO_ROLE="${SO_ROLE:-ryokubaka.ludus_securityonion}"
SO_VM_IP="${SO_VM_IP:-10.1.10.20}"
SO_SSH_USER="${SO_SSH_USER:-onion}"
SO_SSH_PASS="${SO_SSH_PASS:-onion}"
DEPLOY_TIMEOUT_SEC="${DEPLOY_TIMEOUT_SEC:-7200}"
LOG_POLL_SEC="${LOG_POLL_SEC:-30}"
CLEANUP_BEFORE="${CLEANUP_BEFORE:-1}"
FORCE_DEPLOY="${FORCE_DEPLOY:-1}"
SKIP_SOURCE_SYNC="${SKIP_SOURCE_SYNC:-0}"
MODE="${1:-full}"

LOG_PATH="$(ludus_test_ansible_log_path "${LUDUS_RANGE}")"
MARKER_PATH="/etc/ludus-so-setup-complete"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

so_vm_ip() {
  if [ -n "${SO_VM_IP}" ]; then
    echo "${SO_VM_IP}"
    return 0
  fi
  local cfg_path
  cfg_path="$(ludus_test_range_config_path "${LUDUS_RANGE}")"
  ludus_test_ssh "python3 - <<PY
import re, yaml, sys
path = '${cfg_path}'
with open(path) as f:
    raw = f.read()
    data = yaml.safe_load(raw)
for vm in data.get('ludus') or []:
    if vm.get('vm_name') == '${SO_VM}':
        vlan = int(vm.get('vlan', 10))
        last = int(vm.get('ip_last_octet', 20))
        m = re.search(r'range_second_octet[:\\s]+(\\d+)', raw)
        oct2 = int(m.group(1)) if m else 1
        print(f'10.{oct2}.{vlan}.{last}')
        sys.exit(0)
print('', end='')
PY" 2>/dev/null || true
}

so_ssh() {
  local ip="$1"
  shift
  ludus_test_ssh "command -v sshpass >/dev/null 2>&1 || apt-get update -qq && apt-get install -y -qq sshpass"
  ludus_test_ssh "sshpass -p '${SO_SSH_PASS}' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=20 ${SO_SSH_USER}@${ip} $*"
}

preflight() {
  ludus_test_ensure_key
  log "Ludus host=${LUDUS_HOST} user=${LUDUS_USER} range=${LUDUS_RANGE} vm=${SO_VM} role=${SO_ROLE}"
  ludus_test_ssh "test -f $(ludus_test_range_config_path "${LUDUS_RANGE}")" \
    || die "range ${LUDUS_RANGE} not found under ${LUDUS_INSTALL_ROOT}/ranges"
}

sync_and_install() {
  if [ "${SKIP_SOURCE_SYNC}" = "1" ]; then
    log "SKIP_SOURCE_SYNC=1 — using role already on Ludus host"
  else
    ludus_test_sync_source
  fi
  ludus_test_install_local_role "${SO_ROLE}"
  log "Role installed under ${LUDUS_INSTALL_ROOT}/users/${LUDUS_USER}/.ansible/roles/${SO_ROLE}"
}

cleanup_so_vm() {
  [ "${CLEANUP_BEFORE}" = "1" ] || { log "CLEANUP_BEFORE=0 — skipping VM cleanup"; return 0; }
  local ip
  ip="$(so_vm_ip)"
  [ -n "${ip}" ] || die "cannot resolve SO VM IP for cleanup"
  log "Cleaning ${SO_VM}@${ip} (marker, bond0, stale so-setup)"
  ludus_test_cleanup_so_vm "${SO_VM}" "${ip}"
}

ensure_so_ready() {
  local ip
  ip="$(so_vm_ip)"
  [ -n "${ip}" ] || die "cannot resolve SO VM IP"
  ludus_test_wait_deploy_idle "${LUDUS_RANGE}" "${DEPLOY_IDLE_WAIT_SEC:-120}" || die "another deploy is still running on ${LUDUS_RANGE}"
  ludus_test_ensure_so_reachable "${ip}" "${SO_VM}" || die "SO VM ${SO_VM} unreachable at ${ip} after reboot retries"
}

deploy_only_roles() {
  local force_flag=()
  [ "${FORCE_DEPLOY}" = "1" ] && force_flag=(--force)
  ensure_so_ready
  log "Starting deploy: limit=${SO_VM} tags=user-defined-roles only-roles=${SO_ROLE}"
  set +e
  ludus_test_as_user range deploy \
    -r "${LUDUS_RANGE}" \
    --limit "${SO_VM}" \
    --tags user-defined-roles \
    --only-roles "${SO_ROLE}" \
    "${force_flag[@]}"
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || die "ludus range deploy returned ${rc}"
}

log_line_count() {
  ludus_test_ssh "wc -l < '${LOG_PATH}' 2>/dev/null | tr -d ' ' || echo 0"
}

fetch_log_from_line() {
  local from_line="$1"
  ludus_test_ssh "tail -n +${from_line} '${LOG_PATH}' 2>/dev/null || true"
}

guest_sosetup_tail() {
  local ip min_mtime="${1:-0}"
  ip="$(so_vm_ip)"
  [ -n "$ip" ] || return 0
  ludus_test_ssh "timeout 12 sshpass -p '${SO_SSH_PASS}' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=6 '${SO_SSH_USER}@${ip}' \
    'sudo bash -lc \"L=/root/sosetup.log; [[ -f \\\$L ]] || exit 0; mt=\\\$(stat -c %Y \\\$L 2>/dev/null || echo 0); [[ \\\$mt -ge ${min_mtime} ]] || exit 0; echo SOSETUP_MTIME=\\\$mt; tail -8 \\\$L\"' 2>/dev/null" || true
}

monitor_deploy() {
  local start_lines start_ts now elapsed state tail_out current_lines new_lines so_tail
  start_lines="$(log_line_count)"
  start_ts=$(date +%s)
  log "Monitoring ${LOG_PATH} + guest /root/sosetup.log (timeout ${DEPLOY_TIMEOUT_SEC}s, poll ${LOG_POLL_SEC}s)"

  while true; do
    now=$(date +%s)
    elapsed=$((now - start_ts))
    [ "$elapsed" -lt "${DEPLOY_TIMEOUT_SEC}" ] || die "Deploy timed out after ${DEPLOY_TIMEOUT_SEC}s"

    state="$(ludus_test_range_state "${LUDUS_RANGE}")"
    current_lines="$(log_line_count)"
    new_lines=$((current_lines - start_lines))
    tail_out=""
    if [ "$new_lines" -gt 0 ]; then
      tail_out="$(ludus_test_ssh "tail -n ${new_lines} '${LOG_PATH}' 2>/dev/null || true")"
      start_lines="$current_lines"
    fi

    if [ -n "${tail_out}" ]; then
      # Avoid matching FAIL_RE source text dumped in -vvvv ansible logs.
      printf '%s\n' "${tail_out}" | grep -E \
        'PLAY RECAP|FAILED!|fatal:|MNIC_IP=|Timed out waiting|DNS preflight|Write setup-complete marker|started pid=|complete-so-status|Rescan PCI|Waiting up to|unreachable=[1-9]|failed=[1-9]|unknown connection .|Could not resolve host|failed-log-running|^failed-log$' \
        || true
    fi

    # Only show sosetup lines from this deploy window (mtime >= start).
    so_tail="$(guest_sosetup_tail "${start_ts}")"
    if [ -n "${so_tail}" ]; then
      printf '%s\n' "${so_tail}" | grep -E \
        'SOSETUP_MTIME=|Setting up|Repo Sync|Could not resolve|unknown connection|bonding_masters|Setup complete|unrecoverable|nmcli con mod|ERROR|Error:' \
        || true
      if printf '%s\n' "${so_tail}" | grep -qiE 'unknown connection .bonding_masters|Setup encountered an unrecoverable'; then
        die "Guest sosetup terminal failure — see /root/sosetup.log on ${SO_VM}"
      fi
    fi

    if printf '%s\n' "${tail_out}" | grep -q "PLAY RECAP"; then
      # Only judge the *last* PLAY RECAP block (earlier until-retries leave failed=1 noise in the tail window).
      last_recap="$(printf '%s\n' "${tail_out}" | awk '/^PLAY RECAP/{buf=""; next} {buf=buf $0 ORS} END{printf "%s", buf}')"
      if printf '%s\n' "${last_recap}" | grep -E "^${SO_VM}[[:space:]]+:.*failed=0.*unreachable=0" >/dev/null 2>&1; then
        log "PLAY RECAP OK for ${SO_VM}"
        return 0
      fi
      if printf '%s\n' "${last_recap}" | grep -E "^${SO_VM}[[:space:]]+:.*(failed=[1-9]|unreachable=[1-9])" >/dev/null 2>&1; then
        die "PLAY RECAP reports failure — see ${LOG_PATH} on Ludus host"
      fi
    fi

    if [ -n "${state}" ] && [ "${state}" != "DEPLOYING" ] && [ "${state}" != "WAITING" ]; then
      if ludus_test_ansible_running; then
        log "Range state=${state} but ansible still running — waiting"
      else
        log "Range state=${state}"
        case "${state}" in
          SUCCESS|DEPLOYED) return 0 ;;
          ABORTED|FAILED) die "Range ended in state ${state}" ;;
          *) ;;
        esac
      fi
    fi

    log "… still running (${elapsed}s elapsed, state=${state:-unknown})"
    sleep "${LOG_POLL_SEC}"
  done
}

verify_so_vm() {
  local ip rc=0
  ip="$(so_vm_ip)"
  log "Verifying ${SO_VM} (marker + so-status)"
  if ludus_test_ssh "runuser -u ludus -- ansible ${SO_VM} -i /opt/ludus/ranges/${LUDUS_RANGE}/inventory -m stat -a path=${MARKER_PATH} 2>/dev/null | grep -q '\"exists\": true'"; then
    log "OK: setup marker ${MARKER_PATH} present"
  else
    log "FAIL: missing ${MARKER_PATH}"
    rc=1
  fi
  if ludus_test_ssh "runuser -u ludus -- ansible ${SO_VM} -i /opt/ludus/ranges/${LUDUS_RANGE}/inventory -m shell -a 'command -v so-status && so-status 2>/dev/null | head -8' -b 2>/dev/null"; then
    log "OK: so-status responded"
  else
    log "WARN: so-status missing or not ready"
  fi
  local nics
  nics="$(ludus_test_ssh "runuser -u ludus -- ansible ${SO_VM} -i /opt/ludus/ranges/${LUDUS_RANGE}/inventory -m shell -a 'ls -1 /sys/class/net | grep -vE \"^(lo|docker|veth|br-|tun|wg|bond)\" | paste -sd, -' 2>/dev/null | tail -1" || true)"
  log "Guest NICs: ${nics:-unknown}"
  return "$rc"
}

print_summary() {
  log "Done. Log: root@${LUDUS_HOST}:${LOG_PATH}"
  log "Re-run verify only: CLEANUP_BEFORE=0 $0 verify"
}

case "${MODE}" in
  full)
    preflight
    sync_and_install
    cleanup_so_vm
    deploy_only_roles
    monitor_deploy
    verify_so_vm
    print_summary
    ;;
  deploy)
    preflight
    cleanup_so_vm
    deploy_only_roles
    monitor_deploy
    verify_so_vm
    print_summary
    ;;
  verify)
    preflight
    verify_so_vm
    ;;
  monitor)
    preflight
    monitor_deploy
    verify_so_vm
    print_summary
    ;;
  *)
    echo "Usage: $0 {full|deploy|verify|monitor}" >&2
    exit 1
    ;;
esac

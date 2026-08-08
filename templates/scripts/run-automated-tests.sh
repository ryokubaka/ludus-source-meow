#!/bin/bash
# Automated Security Onion template testing (unit → sync → optional live VM → optional full build).
#
# Usage (from ludus-source-meow repo root or templates/):
#   ./templates/scripts/run-automated-tests.sh unit              # ~1s, local
#   ./templates/scripts/run-automated-tests.sh sync              # push to Ludus packer dir
#   ./templates/scripts/run-automated-tests.sh integration       # guest-agent on live VM
#   ./templates/scripts/run-automated-tests.sh full              # sync + ludus templates build
#
# Env:
#   SO_TEMPLATE=securityonion-2.4   (or securityonion-3)
#   LUDUS_HOST=10.0.20.40
#   LUDUS_SSH_KEY=/tmp/ludus_root_key
#   LUDUS_USER=catshadowstep
#   SO_TEST_IP=                   (optional; auto-scan on Ludus if unset)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SO_TEMPLATE="${SO_TEMPLATE:-securityonion-2.4}"
LUDUS_HOST="${LUDUS_HOST:-10.0.20.40}"
LUDUS_SSH_KEY="${LUDUS_SSH_KEY:-/tmp/ludus_root_key}"
LUDUS_USER="${LUDUS_USER:-catshadowstep}"
LUDUS_PACKER_DIR="/opt/ludus/packer/${SO_TEMPLATE}"
TEMPLATE_LIST_NAME="${SO_TEMPLATE}-x64-template"
MODE="${1:-unit}"

ssh_ludus() {
  ssh -i "$LUDUS_SSH_KEY" -o StrictHostKeyChecking=no "root@${LUDUS_HOST}" "$@"
}

ensure_key() {
  if [ ! -r "$LUDUS_SSH_KEY" ]; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx ludus-ux; then
      docker cp ludus-ux:/app/ssh/id_rsa "$LUDUS_SSH_KEY"
      chmod 600 "$LUDUS_SSH_KEY"
    else
      echo "ERROR: ${LUDUS_SSH_KEY} missing and ludus-ux container not running" >&2
      exit 1
    fi
  fi
}

# CIFS ludus storage can time out when GOAD/range VMs are active. Optional pause/resume.
prepare_ludus_storage_for_build() {
  if [ "${SKIP_GOAD_PAUSE:-0}" = "1" ]; then
    return 0
  fi
  echo "=== pausing GOAD VMs on ludus CIFS (set SKIP_GOAD_PAUSE=1 to skip) ===" >&2
  ssh_ludus "rm -f /var/lock/qemu-server/lock-111.conf; for id in 105 106 109; do qm status \$id 2>/dev/null | grep -q running && qm stop \$id --timeout 60 || true; done"
}

resume_goad_vms() {
  if [ "${SKIP_GOAD_PAUSE:-0}" = "1" ]; then
    return 0
  fi
  echo "=== resuming GOAD VMs ===" >&2
  ssh_ludus "for id in 105 106 109; do qm config \$id >/dev/null 2>&1 && qm start \$id 2>/dev/null || true; done"
}

run_unit() {
  echo "=== unit tests: ${SO_TEMPLATE} ===" >&2
  bash "${ROOT}/${SO_TEMPLATE}/tests/test-qemu-ga-logic.sh"
}

run_sync() {
  ensure_key
  echo "=== syncing ${SO_TEMPLATE} → ${LUDUS_HOST}:${LUDUS_PACKER_DIR} ===" >&2
  find "${ROOT}/${SO_TEMPLATE}" -name '*.sh' -exec sed -i 's/\r$//' {} +
  rsync -avz --delete \
    -e "ssh -i ${LUDUS_SSH_KEY} -o StrictHostKeyChecking=no" \
    "${ROOT}/${SO_TEMPLATE}/" "root@${LUDUS_HOST}:${LUDUS_PACKER_DIR}/"
  ssh_ludus "chown -R ${LUDUS_USER}:ludus ${LUDUS_PACKER_DIR} && chmod +x ${LUDUS_PACKER_DIR}/scripts/*.sh"
  VER="$(ssh_ludus "grep '^SCRIPT_VERSION=' ${LUDUS_PACKER_DIR}/scripts/packer-provision-via-dhcp.sh | head -1")"
  echo "Server script version: ${VER}" >&2
}

ludus_as_user() {
  local api_key
  api_key="$(ssh_ludus "grep LUDUS_API_KEY /home/${LUDUS_USER}/.bashrc | cut -d= -f2")"
  ssh_ludus "runuser -u ${LUDUS_USER} -- env LUDUS_API_KEY='${api_key}' LUDUS_VERSION=2 ludus $*"
}

ensure_template_registered() {
  if ! ludus_as_user templates list 2>/dev/null | grep -qF "${TEMPLATE_LIST_NAME}"; then
    echo "=== registering ${TEMPLATE_LIST_NAME} ===" >&2
    ludus_as_user templates add -d "${LUDUS_PACKER_DIR}"
  fi
}

run_integration() {
  ensure_key
  echo "=== integration test on Ludus (guest-agent + ansible) ===" >&2
  local ga_cmd full_cmd rc=0
  ga_cmd="cd ${LUDUS_PACKER_DIR} && ANSIBLE_HOME=/opt/ludus/users/${LUDUS_USER}/.ansible SSH_PASS=onion"
  [ -n "${SO_TEST_IP:-}" ] && ga_cmd="${ga_cmd} SO_TEST_IP=${SO_TEST_IP}"
  ga_cmd="${ga_cmd} ./scripts/test-provision-against-vm.sh --guest-agent-only"
  echo "--- guest-agent only ---" >&2
  ssh_ludus "$ga_cmd" || rc=1
  if [ "$rc" -eq 0 ]; then
    echo "--- full ansible provision ---" >&2
    full_cmd="cd ${LUDUS_PACKER_DIR} && ANSIBLE_HOME=/opt/ludus/users/${LUDUS_USER}/.ansible SSH_PASS=onion"
    [ -n "${SO_TEST_IP:-}" ] && full_cmd="${full_cmd} SO_TEST_IP=${SO_TEST_IP}"
    full_cmd="${full_cmd} ./scripts/test-provision-against-vm.sh"
    ssh_ludus "$full_cmd" || rc=1
  fi
  return "$rc"
}

run_full_build() {
  run_sync
  ensure_template_registered
  prepare_ludus_storage_for_build
  echo "=== starting ludus templates build -n ${TEMPLATE_LIST_NAME} ===" >&2
  set +e
  ludus_as_user templates build -n "${TEMPLATE_LIST_NAME}"
  BUILD_RC=$?
  set -e
  resume_goad_vms
  echo "Build triggered. Monitoring latest packer tmp log..." >&2
  local log=""
  for _ in $(seq 1 30); do
    log="$(ssh_ludus "ls -t /opt/ludus/users/${LUDUS_USER}/packer/tmp/packer-log* 2>/dev/null | head -1")"
    [ -n "$log" ] && break
    sleep 2
  done
  if [ -z "$log" ]; then
    echo "WARN: no packer tmp log found; tailing packer.log" >&2
    log="/opt/ludus/users/${LUDUS_USER}/packer.log"
  fi
  echo "Log: ${log}" >&2
  for _ in $(seq 1 40); do
    ssh_ludus "grep -E 'H37|SSH ready|PLAY RECAP|errored|artifact|Build.*finished' '$log' 2>/dev/null | tail -5" || true
    if ssh_ludus "grep -qE 'Build.*finished but no artifacts|Build.*finished successfully|errored after' '$log' 2>/dev/null"; then
      break
    fi
    ssh_ludus "pgrep -f 'packer build.*${SO_TEMPLATE}' >/dev/null" || break
    sleep 60
  done
  ludus_as_user templates list 2>/dev/null | grep -F "${TEMPLATE_LIST_NAME}" || true
  return "${BUILD_RC:-0}"
}

case "$MODE" in
  unit) run_unit ;;
  sync) run_sync ;;
  integration) run_integration ;;
  full) run_full_build ;;
  all)
    run_unit
    run_sync
    if run_integration; then
      echo "Integration passed (live VM was available)." >&2
    else
      echo "No live VM or integration failed — run 'full' for end-to-end packer build." >&2
      exit 1
    fi
    ;;
  *)
    echo "Usage: $0 {unit|sync|integration|full|all}" >&2
    exit 1
    ;;
esac

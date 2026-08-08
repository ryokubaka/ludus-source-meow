#!/bin/bash
# Install Oracle Linux ansible group_vars on the Ludus host (required for SO templates).
# Ludus dynamic inventory assigns proxmox_os_id=ol hosts to group "ol"; without this file
# ansible_user is unset and deploy falls back to the ludus controller user.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LUDUS_HOST="${LUDUS_HOST:-10.0.20.40}"
DEST="${LUDUS_GROUP_VARS_DIR:-/opt/ludus/ansible/range-management/group_vars/ol.yml}"
SSH_KEY="${LUDUS_SSH_KEY:-/tmp/ludus_root_key}"

if [ ! -f "${ROOT}/ansible/group_vars/ol.yml" ]; then
  echo "ERROR: missing ${ROOT}/ansible/group_vars/ol.yml" >&2
  exit 1
fi

SCP_OPTS=(-o StrictHostKeyChecking=no)
[ -r "${SSH_KEY}" ] && SCP_OPTS=(-i "${SSH_KEY}" "${SCP_OPTS[@]}")

echo "Installing ol.yml to root@${LUDUS_HOST}:${DEST}" >&2
scp "${SCP_OPTS[@]}" "${ROOT}/ansible/group_vars/ol.yml" "root@${LUDUS_HOST}:${DEST}"
echo "Done. Re-run range deploy." >&2

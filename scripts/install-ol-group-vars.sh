#!/bin/bash
# Install Oracle Linux ansible group_vars on the Ludus host (required for SO templates).
# Ludus dynamic inventory assigns proxmox_os_id=ol hosts to group "ol"; without this file
# ansible_user is unset and deploy falls back to the ludus controller user.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${LUDUS_GROUP_VARS_DIR:-/opt/ludus/ansible/range-management/group_vars/ol.yml}"
SSH_KEY="${LUDUS_SSH_KEY:-}"

if [ -z "${LUDUS_HOST:-}" ]; then
  echo "ERROR: set LUDUS_HOST to your Ludus server (e.g. LUDUS_HOST=ludus.example.com)" >&2
  exit 1
fi

if [ ! -f "${ROOT}/ansible/group_vars/ol.yml" ]; then
  echo "ERROR: missing ${ROOT}/ansible/group_vars/ol.yml" >&2
  exit 1
fi

SCP_OPTS=(-o StrictHostKeyChecking=no)
if [ -n "${SSH_KEY}" ] && [ -r "${SSH_KEY}" ]; then
  SCP_OPTS=(-i "${SSH_KEY}" "${SCP_OPTS[@]}")
fi

echo "Installing ol.yml to root@${LUDUS_HOST}:${DEST}" >&2
scp "${SCP_OPTS[@]}" "${ROOT}/ansible/group_vars/ol.yml" "root@${LUDUS_HOST}:${DEST}"
echo "Done. Re-run range deploy." >&2

#!/usr/bin/env bash
# Attach SO sniff net1 + hub-mode bridge ageing during Ludus range deploy.
# Uses Proxmox API env vars injected by Ludus ansible (PROXMOX_URL, token, etc.).
set -euo pipefail

: "${PROXMOX_URL:?PROXMOX_URL not set — run during Ludus range deploy}"
: "${PROXMOX_USERNAME:?PROXMOX_USERNAME not set}"
: "${PROXMOX_TOKEN:?PROXMOX_TOKEN not set}"
: "${PROXMOX_SECRET:?PROXMOX_SECRET not set}"
: "${LUDUS_SO_VM_NAME:?LUDUS_SO_VM_NAME not set}"
: "${LUDUS_SO_VMBR:?LUDUS_SO_VMBR not set}"
: "${LUDUS_SO_SNIFF_TAG:?LUDUS_SO_SNIFF_TAG not set}"

CURL=(curl -fsS)
if [[ "${PROXMOX_INVALID_CERT:-false}" == "true" ]]; then
  CURL+=(-k)
fi

AUTH="Authorization: PVEAPIToken=${PROXMOX_USERNAME}!${PROXMOX_TOKEN}=${PROXMOX_SECRET}"
BASE="${PROXMOX_URL%/}/api2/json"
NETSPEC="virtio,bridge=${LUDUS_SO_VMBR},tag=${LUDUS_SO_SNIFF_TAG},firewall=0"
TARGET_NODE="${LUDUS_SO_TARGET_NODE:-}"

lookup="$("${CURL[@]}" -H "$AUTH" "${BASE}/cluster/resources?type=vm")"
read -r NODE VMID <<< "$(
  LUDUS_SO_VM_NAME="$LUDUS_SO_VM_NAME" LUDUS_SO_TARGET_NODE="$TARGET_NODE" python3 - <<'PY'
import json, os, sys
data = json.load(sys.stdin)
name = os.environ["LUDUS_SO_VM_NAME"]
target = os.environ.get("LUDUS_SO_TARGET_NODE", "").strip()
matches = [
    row for row in data.get("data", [])
    if row.get("name") == name and row.get("type") == "qemu"
]
if target:
    matches = [row for row in matches if row.get("node") == target]
if not matches:
    sys.exit(1)
row = matches[0]
print(row["node"], row["vmid"])
PY
<<<"$lookup"
)" || {
  echo "VM ${LUDUS_SO_VM_NAME} not found in Proxmox cluster resources" >&2
  exit 1
}

cfg="$("${CURL[@]}" -H "$AUTH" "${BASE}/nodes/${NODE}/qemu/${VMID}/config")"
net1="$(python3 - <<'PY'
import json, sys
data = json.load(sys.stdin)
print(data.get("data", {}).get("net1", "") or "")
PY
<<<"$cfg")"

if [[ -n "$net1" ]]; then
  if [[ "$net1" == *"bridge=${LUDUS_SO_VMBR}"* && "$net1" == *"tag=${LUDUS_SO_SNIFF_TAG}"* ]]; then
    echo "net1 already sniff-ready on VMID ${VMID} (${LUDUS_SO_VM_NAME})"
  else
    echo "net1 already set to unexpected value: ${net1}" >&2
    exit 3
  fi
else
  "${CURL[@]}" -H "$AUTH" -X PUT --data-urlencode "net1=${NETSPEC}" \
    "${BASE}/nodes/${NODE}/qemu/${VMID}/config" >/dev/null
  echo "added net1=${NETSPEC} on VMID ${VMID} (${LUDUS_SO_VM_NAME})"
fi

set_bridge_ageing() {
  local vmbr="$1"
  if command -v brctl >/dev/null 2>&1 && ip link show "$vmbr" &>/dev/null; then
    brctl setageing "$vmbr" 0 || true
    ip link set dev "$vmbr" type bridge ageing_time 0 2>/dev/null || true
    echo "bridge-ageing 0 on ${vmbr} (local)"
    return 0
  fi
  return 1
}

if set_bridge_ageing "${LUDUS_SO_VMBR}"; then
  :
else
  SSH_HOST="${LUDUS_SO_PROXMOX_SSH_HOST:-${PROXMOX_HOSTNAME:-}}"
  SSH_USER="${LUDUS_SO_PROXMOX_SSH_USER:-root}"
  SSH_PORT="${LUDUS_SO_PROXMOX_SSH_PORT:-22}"
  if [[ -n "$SSH_HOST" ]]; then
    SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p "$SSH_PORT" "${SSH_USER}@${SSH_HOST}")
    if "${SSH[@]}" "command -v brctl >/dev/null && ip link show '${LUDUS_SO_VMBR}'" >/dev/null 2>&1; then
      "${SSH[@]}" "brctl setageing '${LUDUS_SO_VMBR}' 0; ip link set dev '${LUDUS_SO_VMBR}' type bridge ageing_time 0 2>/dev/null || true"
      echo "bridge-ageing 0 on ${LUDUS_SO_VMBR} (via ${SSH_USER}@${SSH_HOST})"
    else
      echo "WARN: ${LUDUS_SO_VMBR} not found on ${SSH_HOST}; set bridge-ageing 0 manually for packet capture" >&2
    fi
  else
    echo "WARN: could not set bridge-ageing on ${LUDUS_SO_VMBR}; see https://docs.ludus.cloud/docs/networking#packet-capture" >&2
  fi
fi

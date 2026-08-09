#!/bin/bash
# Monitor SO3 packer build until BUILT or failed. Keeps GOAD paused.
set -uo pipefail
KEY="${LUDUS_SSH_KEY:-/tmp/ludus_root_key}"
HOST="${LUDUS_HOST:-10.0.20.40}"
LOG="${1:-/tmp/so3-packer-monitor.log}"
echo "monitor start $(date -Is)" | tee "$LOG"

while true; do
  out=$(ssh -i "$KEY" -o StrictHostKeyChecking=no "root@${HOST}" bash -s <<'EOS'
set -uo pipefail
PLOG=$(ls -t /opt/ludus/users/catshadowstep/packer/tmp/packer-log* 2>/dev/null | head -1)
echo "PLOG:${PLOG:-none}"
if [ -n "${PLOG:-}" ]; then
  sed 's/\x1b\[[0-9;]*m//g' "$PLOG" | grep -E 'ui:|ui error:|Creating|Starting|Waiting|SSH|errored|finished|Provisioning|H37|artifact|Error' | tail -15
fi
echo ---
qm list | grep -E '113|securityonion-3' || true
qm status 113 2>/dev/null || true
if ! pgrep -af 'packer build.*securityonion-3' >/dev/null; then
  echo NO_PACKER
else
  pgrep -af 'packer build.*securityonion-3' | head -2
fi
API=$(grep -m1 LUDUS_API_KEY /home/catshadowstep/.bashrc | cut -d= -f2- | tr -d "'")
runuser -u catshadowstep -- env LUDUS_API_KEY="$API" LUDUS_VERSION=2 ludus templates list 2>/dev/null | grep securityonion-3 || true
EOS
)
  {
    echo "===== $(date -Is) ====="
    echo "$out"
  } | tee -a "$LOG"

  if echo "$out" | grep -qE '✅ BUILT|finished successfully'; then
    echo DONE_OK | tee -a "$LOG"
    # resume GOAD
    ssh -i "$KEY" -o StrictHostKeyChecking=no "root@${HOST}" \
      'for id in 105 106 109; do qm start $id 2>/dev/null || true; done'
    exit 0
  fi
  if echo "$out" | grep -qE 'errored after|Error creating'; then
    if ! echo "$out" | grep -q BUILDING; then
      echo DONE_FAIL | tee -a "$LOG"
      exit 1
    fi
  fi
  if echo "$out" | grep -q NO_PACKER && echo "$out" | grep -q 'NOT BUILT'; then
    echo DONE_FAIL_NOPACKER | tee -a "$LOG"
    exit 1
  fi
  sleep 60
done

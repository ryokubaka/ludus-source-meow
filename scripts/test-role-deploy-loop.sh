#!/bin/bash
# Retry ludus_securityonion only-roles deploy until verify passes or max attempts.
#
# Usage:
#   ./scripts/test-role-deploy-loop.sh
#   MAX_ATTEMPTS=3 DEPLOY_TIMEOUT_SEC=7200 ./scripts/test-role-deploy-loop.sh
#
# Logs: /tmp/ludus-so-role-test-<timestamp>.log
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-5}"
LOG_FILE="${LOG_FILE:-/tmp/ludus-so-role-test-$(date +%Y%m%d-%H%M%S).log}"
LOCK_FILE="${LOCK_FILE:-/tmp/ludus-so-role-deploy.lock}"

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  echo "Another SO deploy loop holds ${LOCK_FILE} — exit" >&2
  exit 1
fi

exec > >(tee -a "${LOG_FILE}") 2>&1

echo "=== SO role deploy loop — max ${MAX_ATTEMPTS} attempts ==="
echo "Log: ${LOG_FILE}"

attempt=1
while [ "$attempt" -le "${MAX_ATTEMPTS}" ]; do
  echo ""
  echo "========== Attempt ${attempt}/${MAX_ATTEMPTS} $(date -Iseconds) =========="
  if "${SCRIPT_DIR}/test-role-deploy.sh" full; then
    echo "SUCCESS on attempt ${attempt}"
    exit 0
  fi
  echo "Attempt ${attempt} failed — waiting 60s before retry"
  attempt=$((attempt + 1))
  sleep 60
done

echo "FAILED after ${MAX_ATTEMPTS} attempts — see ${LOG_FILE}"
exit 1

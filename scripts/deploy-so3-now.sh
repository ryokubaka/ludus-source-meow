#!/bin/bash
# Recreate catshadowstep-so from SO3 template and run securityonion role.
set -euo pipefail
KEY="${LUDUS_SSH_KEY:-/tmp/ludus_root_key}"
HOST="${LUDUS_HOST:-10.0.20.40}"
LOG="${1:-/tmp/so3-vm-recreate.log}"

ssh -i "$KEY" -o StrictHostKeyChecking=no "root@${HOST}" bash -s <<'EOS' | tee "$LOG"
set -euo pipefail
API=$(grep -m1 LUDUS_API_KEY /home/catshadowstep/.bashrc | cut -d= -f2- | tr -d "'")
ludus_u() { runuser -u catshadowstep -- env LUDUS_API_KEY="$API" LUDUS_VERSION=2 ludus "$@"; }

echo "START_DEPLOY $(date -Is)"
# Clone missing SO VM + run user role (so-setup). Skip full-range network/sysprep noise.
ludus_u range deploy \
  -l catshadowstep-so \
  -t vm-deploy,user-defined-roles \
  --only-roles ryokubaka.ludus_securityonion \
  --force
echo "DEPLOY_RC:$?"
ludus_u range status
echo "END_DEPLOY $(date -Is)"
EOS

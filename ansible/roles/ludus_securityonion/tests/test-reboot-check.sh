#!/bin/bash
# Exercises ludus-so-reboot-check without a Security Onion host.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
check="$root/files/ludus-so-reboot-check"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

none="$tmp/none"
printf '#!/bin/bash\nexit 0\n' >"$tmp/ok"
printf '#!/bin/bash\nexit 1\n' >"$tmp/need"
chmod +x "$tmp/ok" "$tmp/need" "$check"

out=$(
  REBOOT_REQUIRED_FILE="$none" \
  STATUS_FILES="$tmp/missing" \
  NEEDS_RESTARTING_LOG="$tmp/log" \
  "$check"
)
grep -qx 'action=ok' <<<"$out"

out=$(
  NEEDS_RESTARTING_BIN="$tmp/need" \
  REBOOT_REQUIRED_FILE="$none" \
  STATUS_FILES="$tmp/missing" \
  NEEDS_RESTARTING_LOG="$tmp/log" \
  "$check"
)
grep -qx 'action=reboot' <<<"$out"
grep -qx 'reason=needs-restarting' <<<"$out"

printf '1\n' >"$tmp/flag"
out=$(
  NEEDS_RESTARTING_BIN="$tmp/ok" \
  STATUS_FILES="$tmp/flag" \
  REBOOT_REQUIRED_FILE="$none" \
  NEEDS_RESTARTING_LOG="$tmp/log" \
  "$check"
)
grep -qx 'action=refresh' <<<"$out"

out=$(
  NEEDS_RESTARTING_BIN=- \
  STATUS_FILES="$tmp/flag" \
  REBOOT_REQUIRED_FILE="$none" \
  NEEDS_RESTARTING_LOG="$tmp/log" \
  "$check"
)
grep -qx 'action=reboot' <<<"$out"
grep -qx 'reason=status-file' <<<"$out"

: >"$tmp/required"
out=$(
  REBOOT_REQUIRED_FILE="$tmp/required" \
  STATUS_FILES="$tmp/missing" \
  NEEDS_RESTARTING_BIN="$tmp/ok" \
  NEEDS_RESTARTING_LOG="$tmp/log" \
  "$check"
)
grep -qx 'action=reboot' <<<"$out"
grep -qx 'reason=reboot-required' <<<"$out"

echo "ok"

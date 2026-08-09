#!/bin/bash
# Fast unit tests for install-qemu-guest-agent.sh (no SO VM, no packer).
# Run from dev machine or Ludus host: bash tests/test-qemu-ga-logic.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/install-qemu-guest-agent.sh"

pass=0
fail=0

assert() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
    echo "PASS: ${desc}"
  else
    fail=$((fail + 1))
    echo "FAIL: ${desc}" >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual}" >&2
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    pass=$((pass + 1))
    echo "PASS: ${desc}"
  else
    fail=$((fail + 1))
    echo "FAIL: ${desc}" >&2
    echo "  missing: ${needle}" >&2
    echo "  in: ${haystack}" >&2
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "${TMP}/repo"
: >"${TMP}/repo/liburing-2.5-1.el9.x86_64.rpm"
: >"${TMP}/repo/liburing-2.6-1.el9.x86_64.rpm"
: >"${TMP}/repo/qemu-guest-agent-9.1.0-29.el9_7.6.x86_64.rpm"

export SO_REPO_PATHS="${TMP}/repo"

assert "find_local_repo" "${TMP}/repo" "$(find_local_repo)"
assert "find_rpm liburing latest" \
  "${TMP}/repo/liburing-2.6-1.el9.x86_64.rpm" \
  "$(find_rpm "${TMP}/repo" liburing)"

plan="$(plan_local_install "${TMP}/repo" | tr '\n' ' ' | sed 's/ $//')"
assert_contains "plan includes liburing" "liburing-2.6" "$plan"
assert_contains "plan includes guest-agent" "qemu-guest-agent-9.1.0" "$plan"

export DRY_RUN=1
if install_from_local_repo "${TMP}/repo"; then
  pass=$((pass + 1))
  echo "PASS: install_from_local_repo dry-run"
else
  fail=$((fail + 1))
  echo "FAIL: install_from_local_repo dry-run" >&2
fi

bash -n "${ROOT}/scripts/install-qemu-guest-agent.sh"
bash -n "${ROOT}/scripts/packer-provision-via-dhcp.sh"
pass=$((pass + 1))
echo "PASS: bash -n syntax checks"

echo "---"
echo "Results: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]

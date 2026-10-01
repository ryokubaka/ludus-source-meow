#!/bin/bash
# so-zeek / so-suricata come up during the boot highstate, which outlasts a
# 5 minute Ansible async cap. This checks one poll of the helper with fake
# docker and pgrep. No Security Onion VM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/files/ludus-so-wait-sensors"
pass=0
fail=0

assert() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass=$((pass + 1))
    echo "PASS: ${desc}"
  else
    fail=$((fail + 1))
    echo "FAIL: ${desc}" >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual}" >&2
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"
export LUDUS_SO_SENSOR_STATE="$TMP/state"
export PATH="$TMP/bin:/usr/bin:/bin"

cat > "$TMP/bin/docker" <<'EOF'
#!/bin/bash
name="${*: -1}"
case "$name" in
  so-zeek)
    if [[ "${ZEEK_UP:-0}" == 1 ]]; then echo true; exit 0; fi
    echo missing >&2
    exit 1
    ;;
  so-suricata)
    if [[ "${SURI_UP:-0}" == 1 ]]; then echo true; exit 0; fi
    echo missing >&2
    exit 1
    ;;
esac
exit 1
EOF
cat > "$TMP/bin/pgrep" <<'EOF'
#!/bin/bash
if [[ "${HIGHSTATE:-0}" == 1 ]]; then exit 0; fi
exit 1
EOF
cat > "$TMP/bin/so-zeek-start" <<'EOF'
#!/bin/bash
echo zeek >> "$LUDUS_SO_SENSOR_STATE/starts"
EOF
cat > "$TMP/bin/so-suricata-start" <<'EOF'
#!/bin/bash
echo suricata >> "$LUDUS_SO_SENSOR_STATE/starts"
EOF
cat > "$TMP/bin/timeout" <<'EOF'
#!/bin/bash
shift
exec "$@"
EOF
chmod +x "$TMP/bin/"*

run() {
  bash "$HELPER"
}

set +e
out=$(ZEEK_UP=1 SURI_UP=1 run 2>"$TMP/err")
rc=$?
set -e
assert "both running exits 0" "0" "$rc"
assert "both running reports sensors-up" "sensors-up zeek=up suricata=up" "$out"

set +e
out=$(ZEEK_UP=1 SURI_UP=0 HIGHSTATE=1 run 2>"$TMP/err")
rc=$?
set -e
assert "highstate still running exits 2" "2" "$rc"
assert "highstate poll does not start sensors" "waiting-highstate zeek=up suricata=down" "$out"
assert "highstate poll does not call start" "" "$(cat "$TMP/state/starts" 2>/dev/null || true)"

set +e
out=$(ZEEK_UP=1 SURI_UP=0 HIGHSTATE=0 run 2>"$TMP/err")
rc=$?
set -e
assert "after highstate a missing sensor exits 2" "2" "$rc"
assert "after highstate starts the missing sensor once" "started-sensors zeek=up suricata=down" "$out"
assert "start helper ran suricata" "suricata" "$(cat "$TMP/state/starts")"

set +e
out=$(ZEEK_UP=1 SURI_UP=0 HIGHSTATE=0 run 2>"$TMP/err")
rc=$?
set -e
assert "later polls wait instead of starting again" "2" "$rc"
assert "later polls say waiting-sensors" "waiting-sensors zeek=up suricata=down" "$out"
assert "start helper still ran once" "suricata" "$(cat "$TMP/state/starts")"

echo
echo "${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]

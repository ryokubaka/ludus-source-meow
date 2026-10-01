#!/bin/bash
# The kernel rejects enslaving a 1500 MTU virtio NIC into a 9000 MTU bond
# with "echo: write error: Invalid argument". This runs the helper against a
# fake sysfs so that failure is caught without a Security Onion install.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/files/ludus-so-enslave-sniff"
[[ -x "$HELPER" || -f "$HELPER" ]] || { echo "missing $HELPER" >&2; exit 1; }

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

install_fake_ip() {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/ip" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$LUDUS_TEST_IP_LOG"
if [[ "$1" == "link" && "$2" == "set" && "$4" == "mtu" ]]; then
  echo "$5" > "$LUDUS_SO_SYSFS/$3/mtu"
fi
exit 0
EOF
  chmod +x "$TMP/bin/ip"
}

make_nic() {
  local sys="$1" name="$2" mtu="$3"
  mkdir -p "$sys/$name"
  echo "$mtu" > "$sys/$name/mtu"
}

# bond0 at 9000, ens19 at 1500, no slaves — the so33 failure.
SYS="$TMP/sys"
LOG="$TMP/ip.log"
: > "$LOG"
install_fake_ip
export LUDUS_TEST_IP_LOG="$LOG"
make_nic "$SYS" ens19 1500
make_nic "$SYS" bond0 9000
mkdir -p "$SYS/bond0/bonding"
: > "$SYS/bond0/bonding/slaves"

set +e
out=$(PATH="$TMP/bin:/usr/bin:/bin" \
  LUDUS_SO_SYSFS="$SYS" \
  LUDUS_SO_ENSLAVE_CONF="$TMP/missing.conf" \
  LUDUS_SO_SKIP_NM=1 \
  SNIFF=ens19 MTU=1500 \
  bash "$HELPER" 2>"$TMP/err")
rc=$?
set -e

assert "enslave exits 0 when bond mtu is lowered first" "0" "$rc"
assert "stdout reports the slave" "enslaved ens19 -> bond0" "$out"
assert "bond mtu is 1500 before the nic can join" "1500" "$(cat "$SYS/bond0/mtu")"
assert "slave was added" "+ens19" "$(cat "$SYS/bond0/bonding/slaves")"
if grep -q 'link set bond0 mtu 1500' "$LOG"; then
  pass=$((pass + 1))
  echo "PASS: helper asks ip to lower bond mtu"
else
  fail=$((fail + 1))
  echo "FAIL: helper asks ip to lower bond mtu" >&2
  echo "  ip log: $(cat "$LOG")" >&2
fi

# Already enslaved: do not try to add the nic again.
SYS2="$TMP/sys2"
LOG2="$TMP/ip2.log"
: > "$LOG2"
install_fake_ip
LUDUS_TEST_IP_LOG="$LOG2"
make_nic "$SYS2" ens19 1500
make_nic "$SYS2" bond0 9000
mkdir -p "$SYS2/bond0/bonding"
echo "ens19" > "$SYS2/bond0/bonding/slaves"

set +e
out2=$(PATH="$TMP/bin:/usr/bin:/bin" \
  LUDUS_SO_SYSFS="$SYS2" \
  LUDUS_SO_ENSLAVE_CONF="$TMP/missing.conf" \
  LUDUS_SO_SKIP_NM=1 \
  SNIFF=ens19 MTU=1500 \
  bash "$HELPER" 2>"$TMP/err2")
rc2=$?
set -e

assert "already-enslaved nic exits 0" "0" "$rc2"
assert "already-enslaved nic is bond-ok" "bond-ok=ens19" "$out2"

echo
echo "${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]

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

# NetworkManager is down at SO boot. nmcli exits 8, and that must not abort
# before the iproute path creates a 1500 MTU bond.
SYS3="$TMP/sys3"
LOG3="$TMP/ip3.log"
: > "$LOG3"
install_fake_ip
cat > "$TMP/bin/nmcli" <<'EOF'
#!/bin/bash
echo "Error: NetworkManager is not running." >&2
exit 8
EOF
chmod +x "$TMP/bin/nmcli"
cat > "$TMP/bin/systemctl" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$TMP/bin/systemctl"
# Teach the fake ip to create the bond the way `ip link add` would.
cat > "$TMP/bin/ip" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$LUDUS_TEST_IP_LOG"
if [[ "$1" == "link" && "$2" == "add" ]]; then
  name=""
  prev=""
  for arg in "$@"; do
    if [[ "$prev" == "name" ]]; then
      name="$arg"
    fi
    prev="$arg"
  done
  mkdir -p "$LUDUS_SO_SYSFS/$name/bonding"
  echo 1500 > "$LUDUS_SO_SYSFS/$name/mtu"
  : > "$LUDUS_SO_SYSFS/$name/bonding/slaves"
fi
if [[ "$1" == "link" && "$2" == "set" && "$4" == "mtu" ]]; then
  echo "$5" > "$LUDUS_SO_SYSFS/$3/mtu"
fi
exit 0
EOF
chmod +x "$TMP/bin/ip"
export LUDUS_TEST_IP_LOG="$LOG3"
make_nic "$SYS3" ens19 1500

set +e
out3=$(PATH="$TMP/bin:/usr/bin:/bin" \
  LUDUS_SO_SYSFS="$SYS3" \
  LUDUS_SO_ENSLAVE_CONF="$TMP/missing.conf" \
  SNIFF=ens19 MTU=1500 \
  bash "$HELPER" 2>"$TMP/err3")
rc3=$?
set -e

assert "nmcli exit 8 still creates the bond" "0" "$rc3"
assert "stdout reports the slave after nmcli is skipped" $'created-bond0\nenslaved ens19 -> bond0' "$out3"
assert "new bond mtu follows the nic" "1500" "$(cat "$SYS3/bond0/mtu")"
if grep -q 'NetworkManager is not running' "$TMP/err3"; then
  fail=$((fail + 1))
  echo "FAIL: nmcli failure was treated as fatal" >&2
  echo "  stderr: $(cat "$TMP/err3")" >&2
else
  pass=$((pass + 1))
  echo "PASS: nmcli exit 8 is ignored"
fi

echo
echo "${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]

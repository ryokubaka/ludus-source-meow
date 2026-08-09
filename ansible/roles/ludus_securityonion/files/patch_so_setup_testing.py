#!/usr/bin/env python3
"""Patch Security Onion so-setup TESTING profile NIC detection for Ludus.

Works across SO 2.4 / 3.x — tries exact then regex variants of the TESTING
nic_list/MNIC/BNICS/WEBUSER block. Soft-succeeds with pattern-not-found when
none match (role still passes MNIC/BNICS via env).
"""
from __future__ import annotations

import pathlib
import re
import sys

MARKER = "ludus-so-setup-testing-patch"

NEW = (
    f"\t# {MARKER}: honor env MNIC/BNICS; skip bonding_masters\n"
    '\tALLOW_CIDR="${ALLOW_CIDR:-0.0.0.0/0}"\n'
    "\tnic_list=$(ls -1 /sys/class/net | grep -vE "
    "'^(docker|lo|bond|bonding_masters|veth|br-|vir|tun|wg)')\n"
    '\tMNIC="${MNIC:-$(echo "$nic_list" | head -1)}"\n'
    '\tBNICS="${BNICS:-$(echo "$nic_list" | head -2 | tail -1)}"\n'
    '\tWEBUSER="${WEBUSER:-onionuser@somewhere.invalid}"\n'
    '\tWEBPASSWD1="${WEBPASSWD1:-0n10nus3r}"\n'
    '\tWEBPASSWD2="${WEBPASSWD2:-0n10nus3r}"'
)

# Exact SO 2.4.211 block
OLD_EXACT = (
    "\tALLOW_CIDR=0.0.0.0/0\n"
    "\tnic_list=$(ls -1 /sys/class/net | grep -v docker | grep -v lo)\n"
    '\tMNIC=$(echo "$nic_list" | head -1)\n'
    '\tBNICS=$(echo "$nic_list" | head -2 | tail -1)\n'
    "\tWEBUSER=onionuser@somewhere.invalid\n"
    "\tWEBPASSWD1=0n10nus3r\n"
    "\tWEBPASSWD2=0n10nus3r"
)

# Broader: any TESTING nic_list → WEBUSER block (SO 3.x may tweak greps)
OLD_RE = re.compile(
    r"\tALLOW_CIDR=0\.0\.0\.0/0\n"
    r"\tnic_list=\$\(ls -1 /sys/class/net[^\n]*\)\n"
    r"\tMNIC=\$\(echo \"\$nic_list\" \| head -1\)\n"
    r"\tBNICS=\$\(echo \"\$nic_list\" \| head -2 \| tail -1\)\n"
    r"\tWEBUSER=[^\n]+\n"
    r"\tWEBPASSWD1=[^\n]+\n"
    r"\tWEBPASSWD2=[^\n]+",
    re.MULTILINE,
)


def patch_file(path: pathlib.Path) -> str:
    if not path.is_file():
        return f"missing {path}"
    text = path.read_text()
    if MARKER in text:
        return f"already-patched {path}"
    if OLD_EXACT in text:
        path.write_text(text.replace(OLD_EXACT, NEW, 1))
        return f"patched-exact {path}"
    m = OLD_RE.search(text)
    if m:
        path.write_text(text[: m.start()] + NEW + text[m.end() :])
        return f"patched-regex {path}"
    return f"pattern-not-found {path}"


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: patch_so_setup_testing.py PATH...", file=sys.stderr)
        return 2
    any_present = False
    for arg in sys.argv[1:]:
        status = patch_file(pathlib.Path(arg))
        print(status)
        if not status.startswith("missing "):
            any_present = True
    # Soft-ok when pattern absent (SO may honor env MNIC already); hard-fail only if no file.
    return 0 if any_present else 2


if __name__ == "__main__":
    raise SystemExit(main())

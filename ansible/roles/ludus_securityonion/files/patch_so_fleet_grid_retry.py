#!/usr/bin/env python3
"""Retry elasticfleet.install_agent_grid after a Salt master auth timeout.

so-elastic-fleet-setup treats that one salt-call as fatal. The state is reached
only after Fleet setup has already succeeded, and the usual failure is
"Unable to sign_in to master". Restart Salt and apply that state again instead
of aborting the rest of so-setup.
"""
from __future__ import annotations

import pathlib
import re
import sys

MARKER = "ludus-fleet-grid-retry"

OLD_RE = re.compile(
    r"^[ \t]*if ! so-elastic-fleet-setup; then\n"
    r"[ \t]*fail_setup \"Failed to run so-elastic-fleet-setup\"\n"
    r"[ \t]*fi\n",
    re.MULTILINE,
)


def replacement(indent: str) -> str:
    i2 = indent + "\t"
    i3 = i2 + "\t"
    i4 = i3 + "\t"
    i5 = i4 + "\t"
    return (
        f"{indent}# {MARKER}: install_agent_grid salt auth timeout is fatal upstream;\n"
        f"{indent}# restart salt and retry that state, then continue so-setup.\n"
        f"{indent}if ! so-elastic-fleet-setup; then\n"
        f"{i2}grid_recovered=0\n"
        f"{i2}if grep -qE 'Failure\\(s\\) in elasticfleet.install_agent_grid|Unable to sign_in to master' "
        f"\"${{setup_log:-/root/sosetup.log}}\" /root/sosetup.log /var/log/ludus-so-setup.log 2>/dev/null; then\n"
        f"{i3}for grid_attempt in 1 2 3; do\n"
        f"{i4}systemctl restart salt-master salt-minion >/dev/null 2>&1 || true\n"
        f"{i4}salt_wait=0\n"
        f"{i4}while [ \"$salt_wait\" -lt 12 ]; do\n"
        f"{i5}if salt-call test.ping >/dev/null 2>&1; then\n"
        f"{i5}\tbreak\n"
        f"{i5}fi\n"
        f"{i5}salt_wait=$((salt_wait + 1))\n"
        f"{i5}sleep 5\n"
        f"{i4}done\n"
        f"{i4}if salt-call state.apply elasticfleet.install_agent_grid queue=True; then\n"
        f"{i5}grid_recovered=1\n"
        f"{i5}break\n"
        f"{i4}fi\n"
        f"{i4}printf '\\ninstall_agent_grid retry %s/3 failed\\n' \"$grid_attempt\"\n"
        f"{i3}done\n"
        f"{i2}fi\n"
        f"{i2}if [ \"$grid_recovered\" -ne 1 ]; then\n"
        f"{i3}fail_setup \"Failed to run so-elastic-fleet-setup\"\n"
        f"{i2}fi\n"
        f"{indent}fi\n"
    )


def patch_file(path: pathlib.Path) -> str:
    if not path.is_file():
        return f"missing {path}"
    text = path.read_text()
    if MARKER in text:
        return f"already-patched {path}"
    match = OLD_RE.search(text)
    if not match:
        return f"pattern-not-found {path}"
    indent = re.match(r"[ \t]*", match.group(0)).group(0)
    path.write_text(text[: match.start()] + replacement(indent) + text[match.end() :])
    return f"patched {path}"


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: patch_so_fleet_grid_retry.py PATH...", file=sys.stderr)
        return 2
    any_present = False
    for arg in sys.argv[1:]:
        status = patch_file(pathlib.Path(arg))
        print(status)
        if not status.startswith("missing "):
            any_present = True
    return 0 if any_present else 2


if __name__ == "__main__":
    raise SystemExit(main())

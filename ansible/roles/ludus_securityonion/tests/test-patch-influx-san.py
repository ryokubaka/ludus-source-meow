#!/usr/bin/env python3
"""The InfluxDB certificate state keeps the manager name Telegraf dials."""

from __future__ import annotations

import sys
from pathlib import Path

PATCHER = Path(__file__).resolve().parents[1] / "files" / "patch_so_influx_manager_san.py"
sys.path.insert(0, str(PATCHER.parent))

from patch_so_influx_manager_san import patch_text  # noqa: E402

STOCK = (
    "influxdb_crt:\n"
    "  x509.certificate_managed:\n"
    "    - name: /etc/pki/influxdb.crt\n"
    "    - subjectAltName: DNS:{{ GLOBALS.hostname }}, IP:{{ GLOBALS.node_ip }} \n"
    "    - days_valid: 820\n"
)


def fail(msg: str) -> int:
    print(f"FAIL: {msg}", file=sys.stderr)
    return 1


def main() -> int:
    raw = PATCHER.read_bytes()
    if b"\r" in raw:
        return fail("patcher contains CR")
    updated, status = patch_text(STOCK)
    if status != "patched":
        return fail(f"stock status {status}")
    if "DNS:{{ GLOBALS.hostname }}, DNS:manager, IP:{{ GLOBALS.node_ip }}" not in updated:
        return fail(updated)
    again, status = patch_text(updated)
    if status != "already-patched" or again != updated:
        return fail("second patch was not a no-op")
    print("PASS: manager is added to the InfluxDB certificate names once")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

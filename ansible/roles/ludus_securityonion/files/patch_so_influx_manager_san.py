#!/usr/bin/env python3
"""Keep the name manager on the InfluxDB certificate.

Telegraf and the console post metrics to https://manager:8086. Salt issues
the certificate for the node hostname only. After that hostname changes, TLS
verification fails, process-status metrics never land, and the grid stays Fault.
"""

from __future__ import annotations

import pathlib
import re
import sys

SAN_RE = re.compile(
    r"^(?P<prefix>[ \t]*-[ \t]*subjectAltName:[ \t]*DNS:\{\{ GLOBALS\.hostname \}\})"
    r"(?P<rest>, IP:\{\{ GLOBALS\.node_ip \}\}[ \t]*)$",
    re.M,
)


def patch_text(text: str) -> tuple[str, str]:
    lines = text.splitlines(keepends=True)
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("- subjectAltName:") and "DNS:manager" in stripped:
            return text, "already-patched"
    match = SAN_RE.search(text)
    if not match:
        return text, "pattern-not-found"
    updated = (
        text[: match.start()]
        + match.group("prefix")
        + ", DNS:manager"
        + match.group("rest")
        + text[match.end() :]
    )
    return updated, "patched"


def patch_file(path: pathlib.Path) -> str:
    if not path.is_file():
        return f"missing {path}"
    text = path.read_text()
    updated, status = patch_text(text)
    if status == "patched":
        path.write_text(updated)
    return f"{status} {path}"


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: patch_so_influx_manager_san.py PATH...", file=sys.stderr)
        return 2
    any_present = False
    failed = False
    for arg in sys.argv[1:]:
        status = patch_file(pathlib.Path(arg))
        print(status)
        if status.startswith("missing "):
            continue
        any_present = True
        if status.startswith("pattern-not-found "):
            failed = True
    if not any_present:
        return 2
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Set a Proxmox range bridge to hub mode (ageing_time 0).

The Proxmox API token can open a node console, but that console stops at
"hostname login:" and never becomes a root shell. Hub mode is set by writing
the bridge sysfs file directly, with sudo -n, or over SSH to root on the node.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

BRIDGE_RE = re.compile(r"^vmbr[0-9]+$")
HOST_RE = re.compile(r"^[A-Za-z0-9._:-]+$")


def api_base(url: str) -> str:
    url = url.rstrip("/")
    if url.endswith("/api2/json"):
        return url
    return url + "/api2/json"


def http_json(url: str, auth: str) -> dict:
    req = urllib.request.Request(url, method="GET")
    req.add_header("Authorization", auth)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:400]
        raise SystemExit(
            f"Proxmox API GET {urllib.parse.urlparse(url).path} failed: HTTP {exc.code} {detail}"
        ) from exc


def find_node(base: str, auth: str, names: list[str]) -> str:
    data = http_json(base + "/cluster/resources?type=vm", auth)["data"]
    qemus = [vm for vm in data if vm.get("type") == "qemu"]
    wanted = {n for n in names if n}
    matches = [vm for vm in qemus if vm.get("name") in wanted]
    if not matches:
        matches = [vm for vm in qemus if str(vm.get("name", "")).endswith("-so")]
    if not matches:
        raise SystemExit(
            "Could not find the Security Onion VM in Proxmox "
            f"(tried {', '.join(sorted(wanted)) or '*-so'})."
        )
    node = str(matches[0].get("node") or "")
    if not node:
        raise SystemExit("Proxmox VM record has no node.")
    return node


def ageing_path(bridge: str, sysfs_root: str) -> str:
    return os.path.join(sysfs_root, "class", "net", bridge, "bridge", "ageing_time")


def read_ageing(path: str) -> int | None:
    try:
        return int(open(path, encoding="utf-8").read().strip())
    except (OSError, ValueError):
        return None


def write_local(path: str) -> str | None:
    """Return 'local' or 'sudo' when the write lands, else None."""
    if not os.path.exists(path):
        return None
    before = read_ageing(path)
    if os.access(path, os.W_OK):
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("0\n")
        if read_ageing(path) == 0:
            return "local" if before == 0 else "local"
    sudo = shutil.which("sudo")
    if not sudo:
        return None
    proc = subprocess.run(
        [sudo, "-n", "tee", path],
        input=b"0\n",
        capture_output=True,
        timeout=15,
    )
    if proc.returncode == 0 and read_ageing(path) == 0:
        return "sudo"
    return None


def ssh_targets(url: str, node: str) -> list[str]:
    hosts: list[str] = []
    parsed = urllib.parse.urlparse(url)
    for host in ("127.0.0.1", parsed.hostname or "", node):
        if host and HOST_RE.match(host) and host not in hosts:
            hosts.append(host)
    return hosts


def ssh_set(host: str, bridge: str) -> bool:
    remote = (
        f"f=/sys/class/net/{bridge}/bridge/ageing_time; "
        "test -e \"$f\" || exit 2; "
        "before=$(cat \"$f\"); "
        "echo 0 > \"$f\" || exit 1; "
        "echo LUDUS_AGEING_BEFORE=$before; "
        "echo LUDUS_AGEING=$(cat \"$f\")"
    )
    cmd = [
        os.environ.get("LUDUS_SO_SSH", "ssh"),
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "ConnectTimeout=8",
        "-o",
        "LogLevel=ERROR",
        f"root@{host}",
        remote,
    ]
    key = os.environ.get("LUDUS_SO_SSH_KEY", "")
    if key:
        cmd[1:1] = ["-i", key]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return proc.returncode == 0 and "LUDUS_AGEING=0" in proc.stdout


def set_ageing(url: str, auth: str, node: str, bridge: str, vm_names: list[str]) -> int:
    if not BRIDGE_RE.match(bridge):
        raise SystemExit(f"Refusing unexpected bridge name {bridge!r}.")
    sysfs_root = os.environ.get("LUDUS_SO_SYSFS_ROOT", "/sys")
    path = ageing_path(bridge, sysfs_root)
    before = read_ageing(path)
    method = write_local(path)
    if method is None:
        if not node:
            node = find_node(api_base(url), auth, vm_names)
        tried = []
        for host in ssh_targets(url, node):
            tried.append(host)
            if ssh_set(host, bridge):
                method = f"ssh:{host}"
                break
        if method is None:
            raise SystemExit(
                f"Could not set {bridge} ageing_time to 0. "
                "The Proxmox API console stops at a login prompt, so it cannot run the command. "
                f"Passwordless sudo was not available, and root SSH failed for: {', '.join(tried) or '(none)'}. "
                f"On the Proxmox node run: echo 0 > /sys/class/net/{bridge}/bridge/ageing_time"
            )
    if method in ("local", "sudo"):
        changed = "no" if before == 0 else "yes"
    else:
        changed = "yes"
    print(f"bridge={bridge} node={node or 'local'} ageing=0 changed={changed} method={method}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default=os.environ.get("LUDUS_SO_PVE_URL", ""))
    parser.add_argument("--bridge", default=os.environ.get("LUDUS_SO_VMBR", ""))
    parser.add_argument("--node", default=os.environ.get("LUDUS_SO_PVE_NODE", ""))
    parser.add_argument("--vm-name", action="append", default=None)
    args = parser.parse_args(argv)
    auth = os.environ.get("LUDUS_SO_PVE_AUTH", "")
    if not args.url or not auth or not args.bridge:
        raise SystemExit("Need Proxmox URL, API token, and range bridge name to set hub mode.")
    names = args.vm_name if args.vm_name is not None else [
        n for n in os.environ.get("LUDUS_SO_VM_NAMES", "").split(",") if n
    ]
    return set_ageing(args.url, auth, args.node, args.bridge, names)


if __name__ == "__main__":
    sys.exit(main())

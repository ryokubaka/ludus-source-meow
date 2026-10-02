#!/usr/bin/env python3
"""Set a Proxmox range bridge to hub mode (ageing_time 0).

Direct write, sudo -n, and root SSH are shortcuts. Ludus range users have
neither sudo nor a root SSH key. The API token from the deploy cannot open a
root shell: the console stops at "hostname login:". That token can update
network config. ifreload -a then reconciles every bridge, and a Ludus range
bridge is "bridge-ports none" while QEMU taps are attached live, so a reload
detaches those taps unless every Linux bridge carries
bridge-ports-condone-regex. The update schema has no options field; ovs_options
is a free string the writer emits unescaped, so the following indented lines
become real ifupdown2 settings. The reload counts only when the range bridge
reads 0 and no bridge lost a port.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BRIDGE_RE = re.compile(r"^vmbr[0-9]+$")
HOST_RE = re.compile(r"^[A-Za-z0-9._:-]+$")
IFACE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,30}$")
CONDONE_LINE = "bridge-ports-condone-regex ^(tap|fwpr|fwln|veth)"
AGEING_LINE = "bridge-ageing 0"


def api_base(url: str) -> str:
    url = url.rstrip("/")
    if url.endswith("/api2/json"):
        return url
    return url + "/api2/json"


def http_json(url: str, auth: str, method: str = "GET", payload: dict | None = None) -> dict:
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", auth)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    ctx = ssl._create_unverified_context()
    timeout = float(os.environ.get("LUDUS_SO_HTTP_TIMEOUT", "20"))
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:400]
        raise SystemExit(
            f"Proxmox API {method} {urllib.parse.urlparse(url).path} failed: HTTP {exc.code} {detail}"
        ) from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise SystemExit(
            f"Proxmox API {method} {urllib.parse.urlparse(url).path} failed: {exc}"
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


def condone_supported() -> bool:
    path = os.environ.get(
        "LUDUS_SO_IFUPDOWN_BRIDGE",
        "/usr/share/ifupdown2/addons/bridge.py",
    )
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return False
    return "bridge-ports-condone-regex" in text


def loopback_url(url: str) -> str:
    """Talk to pveproxy on loopback so a bridge reload cannot drop the API connection."""
    parsed = urllib.parse.urlsplit(url)
    port = parsed.port
    netloc = "127.0.0.1" if port is None else f"127.0.0.1:{port}"
    return urllib.parse.urlunsplit((parsed.scheme or "https", netloc, "", "", ""))


def ovs_inject(set_hub: bool) -> str:
    # The writer prints "ovs_options <value>" without escaping newlines, so the
    # indented lines become their own ifupdown2 options.
    lines = ["keep", f"\t{CONDONE_LINE}"]
    if set_hub:
        lines.insert(1, f"\t{AGEING_LINE}")
    return "\n".join(lines)


def ip_fields(cfg: dict) -> dict:
    """Resend addressing. Omitting it makes the update rewrite the iface as manual."""
    fields: dict = {}
    if cfg.get("cidr"):
        fields["cidr"] = cfg["cidr"]
    elif cfg.get("address"):
        address = str(cfg["address"])
        if "/" in address:
            fields["cidr"] = address
        else:
            fields["address"] = address
            if cfg.get("netmask") not in (None, ""):
                fields["netmask"] = cfg["netmask"]
    if cfg.get("gateway"):
        fields["gateway"] = cfg["gateway"]
    if cfg.get("cidr6"):
        fields["cidr6"] = cfg["cidr6"]
    elif cfg.get("address6"):
        address6 = str(cfg["address6"])
        if "/" in address6:
            fields["cidr6"] = address6
        else:
            fields["address6"] = address6
            if cfg.get("netmask6") not in (None, ""):
                fields["netmask6"] = cfg["netmask6"]
    if cfg.get("gateway6"):
        fields["gateway6"] = cfg["gateway6"]
    return fields


def bridge_ports(sysfs_root: str) -> dict[str, list[str]]:
    net = os.path.join(sysfs_root, "class", "net")
    found: dict[str, list[str]] = {}
    if not os.path.isdir(net):
        return found
    for name in sorted(os.listdir(net)):
        if not os.path.isdir(os.path.join(net, name, "bridge")):
            continue
        brif = os.path.join(net, name, "brif")
        if not os.path.isdir(brif):
            found[name] = []
            continue
        found[name] = sorted(entry for entry in os.listdir(brif) if not entry.startswith("."))
    return found


def bridge_addrs() -> dict[str, set[str]]:
    ip_bin = shutil.which("ip")
    if not ip_bin:
        return {}
    try:
        proc = subprocess.run([ip_bin, "-j", "addr"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return {}
    if proc.returncode != 0 or not proc.stdout.strip():
        return {}
    try:
        rows = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {}
    found: dict[str, set[str]] = {}
    for row in rows:
        name = str(row.get("ifname") or "")
        addrs = set()
        for info in row.get("addr_info") or []:
            local = info.get("local")
            if local:
                addrs.add(f"{local}/{info.get('prefixlen')}")
        if name:
            found[name] = addrs
    return found


def apply_via_api(base: str, auth: str, node: str, bridge: str) -> str:
    list_url = f"{base}/nodes/{urllib.parse.quote(node)}/network"
    ifaces = http_json(list_url, auth).get("data") or []
    bridges = []
    for cfg in ifaces:
        name = str(cfg.get("iface") or "")
        if cfg.get("type") != "bridge" or not IFACE_RE.match(name):
            continue
        bridges.append(cfg)
    names = {str(cfg.get("iface")) for cfg in bridges}
    if bridge not in names:
        raise SystemExit(f"Proxmox node {node} has no Linux bridge {bridge}.")
    for cfg in bridges:
        name = str(cfg["iface"])
        payload = {
            "type": "bridge",
            "ovs_options": ovs_inject(name == bridge),
        }
        payload.update(ip_fields(cfg))
        iface_url = f"{list_url}/{urllib.parse.quote(name)}"
        http_json(iface_url, auth, method="PUT", payload=payload)
    upid = http_json(list_url, auth, method="PUT", payload={}).get("data")
    if not upid:
        raise SystemExit(f"Proxmox did not start a network reload for {bridge}.")
    status_url = (
        f"{base}/nodes/{urllib.parse.quote(node)}/tasks/"
        f"{urllib.parse.quote(str(upid), safe='')}/status"
    )
    deadline = time.time() + 90
    while time.time() < deadline:
        status = http_json(status_url, auth).get("data") or {}
        if status.get("status") == "stopped":
            return str(status.get("exitstatus") or "")
        time.sleep(1)
    raise SystemExit(f"Proxmox network reload for {bridge} did not finish.")


def set_ageing(url: str, auth: str, node: str, bridge: str, vm_names: list[str]) -> int:
    if not BRIDGE_RE.match(bridge):
        raise SystemExit(f"Refusing unexpected bridge name {bridge!r}.")
    sysfs_root = os.environ.get("LUDUS_SO_SYSFS_ROOT", "/sys")
    path = ageing_path(bridge, sysfs_root)
    before = read_ageing(path)
    if before == 0:
        print(f"bridge={bridge} node={node or 'local'} ageing=0 changed=no method=present")
        return 0
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
        if method is None and not os.path.exists(path):
            raise SystemExit(
                f"Could not set {bridge} ageing_time to 0. "
                "The Proxmox API console stops at a login prompt, so it cannot run the command. "
                f"Passwordless sudo was not available, and root SSH failed for: {', '.join(tried) or '(none)'}. "
                "This controller cannot see the bridge, so networking was not reloaded. "
                f"On the Proxmox node run: echo 0 > /sys/class/net/{bridge}/bridge/ageing_time"
            )
        if method is None and not condone_supported():
            raise SystemExit(
                f"Could not set {bridge} ageing_time to 0. "
                "The Proxmox API console stops at a login prompt, so it cannot run the command. "
                f"Passwordless sudo was not available, and root SSH failed for: {', '.join(tried) or '(none)'}. "
                "ifupdown2 has no bridge-ports-condone-regex, so networking was not reloaded. "
                f"On the Proxmox node run: echo 0 > /sys/class/net/{bridge}/bridge/ageing_time"
            )
        if method is None:
            ports_before = bridge_ports(sysfs_root)
            addrs_before = bridge_addrs()
            try:
                reload_status = apply_via_api(api_base(loopback_url(url)), auth, node, bridge)
            except SystemExit as exc:
                raise SystemExit(
                    f"Could not set {bridge} ageing_time to 0. "
                    "The Proxmox API console stops at a login prompt, so it cannot run the command. "
                    f"Passwordless sudo was not available, and root SSH failed for: {', '.join(tried) or '(none)'}. "
                    f"{exc}"
                ) from exc
            missing = []
            ports_after = bridge_ports(sysfs_root)
            for name, ports in ports_before.items():
                after_ports = ports_after.get(name)
                if after_ports is None:
                    missing.extend(f"{name}/{port}" for port in ports)
                    continue
                missing.extend(f"{name}/{port}" for port in ports if port not in after_ports)
            lost_addrs = []
            addrs_after = bridge_addrs() if addrs_before else {}
            if addrs_before and addrs_after:
                for name, addrs in addrs_before.items():
                    if not name.startswith("vmbr"):
                        continue
                    gone = addrs - addrs_after.get(name, set())
                    lost_addrs.extend(f"{name}/{addr}" for addr in sorted(gone))
            after = read_ageing(path)
            if missing or lost_addrs or after != 0:
                raise SystemExit(
                    f"Hub mode was not verified on {bridge}. "
                    f"ageing_time reads {after!r}. "
                    f"Bridge ports removed: {', '.join(missing) or 'none'}. "
                    f"Addresses removed: {', '.join(lost_addrs) or 'none'}. "
                    f"Network reload exit: {reload_status}. "
                    "Refusing to report success."
                )
            method = "api"
            reload_note = f" reload={reload_status}"
        else:
            reload_note = ""
    else:
        reload_note = ""
    if method in ("local", "sudo"):
        changed = "no" if before == 0 else "yes"
    else:
        changed = "yes"
    print(
        f"bridge={bridge} node={node or 'local'} ageing=0 changed={changed} "
        f"method={method}{reload_note}"
    )
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

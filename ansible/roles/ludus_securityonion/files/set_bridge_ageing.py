#!/usr/bin/env python3
"""Set a Proxmox range bridge to hub mode (ageing_time 0).

The range user running Ansible cannot sudo on the Ludus host, and the bridge
lives on the Proxmox node. The Ludus API token is root@pam, which can open a
root console on that node. This writes the sysfs value through that console.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import socket
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

AGEING_RE = re.compile(r"LUDUS_AGEING=(\d+)")
BRIDGE_RE = re.compile(r"^vmbr[0-9]+$")


def api_base(url: str) -> str:
    url = url.rstrip("/")
    if url.endswith("/api2/json"):
        return url
    return url + "/api2/json"


def http_json(url: str, auth: str, method: str = "GET", body: bytes | None = None) -> dict:
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Authorization", auth)
    if body is not None:
        req.add_header("Content-Type", "application/x-www-form-urlencoded")
    ctx = ssl._create_unverified_context()
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
            payload = json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:400]
        raise SystemExit(f"Proxmox API {method} {urllib.parse.urlparse(url).path} failed: HTTP {exc.code} {detail}") from exc
    return payload


def find_node(base: str, auth: str, names: list[str]) -> str:
    data = http_json(base + "/cluster/resources?type=vm", auth)["data"]
    qemus = [vm for vm in data if vm.get("type") == "qemu"]
    wanted = {n for n in names if n}
    matches = [vm for vm in qemus if vm.get("name") in wanted]
    if not matches:
        matches = [vm for vm in qemus if str(vm.get("name", "")).endswith("-so")]
    if not matches:
        raise SystemExit(
            "Could not find the Security Onion VM in Proxmox to locate its node "
            f"(tried {', '.join(sorted(wanted)) or '*-so'})."
        )
    node = matches[0].get("node") or ""
    if not node:
        raise SystemExit("Proxmox VM record has no node.")
    return node


def ws_encode(payload: bytes, opcode: int = 1) -> bytes:
    mask = os.urandom(4)
    length = len(payload)
    header = bytearray([0x80 | opcode])
    if length < 126:
        header.append(0x80 | length)
    elif length < 65536:
        header.append(0x80 | 126)
        header.extend(length.to_bytes(2, "big"))
    else:
        header.append(0x80 | 127)
        header.extend(length.to_bytes(8, "big"))
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return bytes(header) + mask + masked


def ws_decode(frame: bytes) -> tuple[int, bytes, int]:
    if len(frame) < 2:
        raise ValueError("short websocket frame")
    opcode = frame[0] & 0x0F
    masked = bool(frame[1] & 0x80)
    length = frame[1] & 0x7F
    offset = 2
    if length == 126:
        length = int.from_bytes(frame[2:4], "big")
        offset = 4
    elif length == 127:
        length = int.from_bytes(frame[2:10], "big")
        offset = 10
    mask = b""
    if masked:
        mask = frame[offset : offset + 4]
        offset += 4
    end = offset + length
    payload = frame[offset:end]
    if masked:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return opcode, payload, end


def open_websocket(host: str, port: int, path: str, auth: str, use_tls: bool) -> socket.socket:
    raw = socket.create_connection((host, port), timeout=20)
    if use_tls:
        ctx = ssl._create_unverified_context()
        sock: socket.socket = ctx.wrap_socket(raw, server_hostname=host)
    else:
        sock = raw
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        f"Authorization: {auth}\r\n"
        "\r\n"
    )
    sock.sendall(req.encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise SystemExit("Proxmox closed the console websocket before the handshake finished.")
        buf += chunk
    head = buf.split(b"\r\n\r\n", 1)[0].decode(errors="replace")
    if " 101 " not in head.split("\r\n", 1)[0]:
        raise SystemExit(f"Proxmox console websocket upgrade failed: {head.splitlines()[0]}")
    return sock


def recv_text(sock: socket.socket, pending: bytearray) -> str:
    while True:
        if len(pending) >= 2:
            try:
                opcode, payload, consumed = ws_decode(bytes(pending))
            except ValueError:
                opcode = None
            else:
                if len(pending) >= consumed:
                    del pending[:consumed]
                    if opcode == 0x8:
                        return ""
                    if opcode in (0x1, 0x2):
                        return payload.decode(errors="replace")
                    continue
        chunk = sock.recv(4096)
        if not chunk:
            return ""
        pending.extend(chunk)


def read_for(sock: socket.socket, pending: bytearray, seconds: float, stop: str | None = None) -> str:
    sock.settimeout(seconds)
    text = ""
    try:
        while stop is None or stop not in text:
            piece = recv_text(sock, pending)
            if not piece:
                break
            text += piece
            if len(text) > 20000:
                text = text[-8000:]
            if stop is None:
                break
    except TimeoutError:
        pass
    except socket.timeout:
        pass
    return text


def console_command(sock: socket.socket, user: str, ticket: str, command: str) -> str:
    pending = bytearray()
    sock.sendall(ws_encode(f"{user}:{ticket}\n".encode()))
    banner = read_for(sock, pending, 5, stop="#")
    sock.sendall(ws_encode((command + "\n").encode()))
    text = banner + read_for(sock, pending, 20, stop="LUDUS_AGEING=")
    sock.sendall(ws_encode(b"exit\n"))
    return text


def parse_ageing(text: str) -> int | None:
    found = AGEING_RE.findall(text)
    if not found:
        return None
    return int(found[-1])


def set_ageing(url: str, auth: str, node: str, bridge: str, vm_names: list[str]) -> int:
    if not BRIDGE_RE.match(bridge):
        raise SystemExit(f"Refusing unexpected bridge name {bridge!r}.")
    base = api_base(url)
    if not node:
        node = find_node(base, auth, vm_names)
    opened = http_json(
        f"{base}/nodes/{urllib.parse.quote(node)}/termproxy",
        auth,
        method="POST",
        body=b"cmd=login",
    )["data"]
    user = opened["user"]
    ticket = opened["ticket"]
    port = int(opened["port"])
    parsed = urllib.parse.urlparse(base)
    host = parsed.hostname or ""
    api_port = parsed.port or (443 if parsed.scheme == "https" else 80)
    path = (
        f"/api2/json/nodes/{urllib.parse.quote(node)}/vncwebsocket"
        f"?port={port}&vncticket={urllib.parse.quote(ticket)}"
    )
    command = (
        f"if [ ! -e /sys/class/net/{bridge}/bridge/ageing_time ]; then "
        f"echo LUDUS_AGEING=missing; exit 1; fi; "
        f"before=$(cat /sys/class/net/{bridge}/bridge/ageing_time); "
        f"echo 0 > /sys/class/net/{bridge}/bridge/ageing_time; "
        f"echo LUDUS_AGEING=$(cat /sys/class/net/{bridge}/bridge/ageing_time); "
        f"echo LUDUS_AGEING_BEFORE=$before"
    )
    sock = open_websocket(host, api_port, path, auth, parsed.scheme == "https")
    try:
        text = console_command(sock, user, ticket, command)
    finally:
        sock.close()
    ageing = parse_ageing(text)
    if ageing is None:
        snippet = text[-500:].replace("\r", "")
        raise SystemExit(
            f"Proxmox node {node} did not report bridge ageing for {bridge}. "
            f"Console said: {snippet!r}"
        )
    if ageing != 0:
        raise SystemExit(f"Bridge {bridge} on {node} ageing_time is {ageing}, expected 0.")
    before = re.findall(r"LUDUS_AGEING_BEFORE=(\d+)", text)
    changed = "yes" if not before or int(before[-1]) != 0 else "no"
    print(f"bridge={bridge} node={node} ageing=0 changed={changed}")
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

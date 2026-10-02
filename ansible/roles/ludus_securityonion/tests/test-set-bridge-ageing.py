#!/usr/bin/env python3
"""Drive set_bridge_ageing against a local fake Proxmox console."""

from __future__ import annotations

import json
import os
import socket
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "files"))
import set_bridge_ageing as hub  # noqa: E402


def server_frame(payload: bytes) -> bytes:
    length = len(payload)
    header = bytearray([0x81])
    if length < 126:
        header.append(length)
    else:
        header.append(126)
        header.extend(length.to_bytes(2, "big"))
    return bytes(header) + payload


class FakeProxmox:
    def __init__(self, ageing: str) -> None:
        self.ageing = ageing
        self.command = ""
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.sock.settimeout(0.2)
        self.port = self.sock.getsockname()[1]
        self.stop = False
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def close(self) -> None:
        self.stop = True
        self.thread.join(timeout=2)
        self.sock.close()

    def serve(self) -> None:
        while not self.stop:
            try:
                conn, _ = self.sock.accept()
            except socket.timeout:
                continue
            try:
                self.handle(conn)
            finally:
                conn.close()

    def handle(self, conn: socket.socket) -> None:
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = conn.recv(4096)
            if not chunk:
                return
            data += chunk
        head, rest = data.split(b"\r\n\r\n", 1)
        request = head.decode(errors="replace")
        line = request.split("\r\n", 1)[0]
        if line.startswith("POST ") and "/termproxy" in line:
            body = json.dumps(
                {"data": {"user": "root@pam", "ticket": "TICKET", "port": 5900, "upid": "UPID"}}
            ).encode()
            conn.sendall(
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                + str(len(body)).encode()
                + b"\r\nConnection: close\r\n\r\n"
                + body
            )
            return
        if line.startswith("GET ") and "/cluster/resources" in line:
            body = json.dumps(
                {"data": [{"type": "qemu", "name": "lab-so", "node": "pve", "vmid": 101}]}
            ).encode()
            conn.sendall(
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                + str(len(body)).encode()
                + b"\r\nConnection: close\r\n\r\n"
                + body
            )
            return
        if "Upgrade: websocket" not in request and b"Upgrade: websocket" not in head:
            conn.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
            return
        conn.sendall(
            b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            b"Sec-WebSocket-Accept: test\r\n\r\n"
        )
        pending = bytearray(rest)
        conn.settimeout(5)
        saw_ticket = False
        while True:
            if len(pending) < 2:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                pending.extend(chunk)
                continue
            try:
                opcode, payload, consumed = hub.ws_decode(bytes(pending))
            except ValueError:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                pending.extend(chunk)
                continue
            if len(pending) < consumed:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                pending.extend(chunk)
                continue
            del pending[:consumed]
            if opcode == 0x8:
                return
            text = payload.decode(errors="replace")
            if not saw_ticket:
                saw_ticket = True
                conn.sendall(server_frame(b"root@pve:~# "))
                continue
            if "echo 0 >" in text:
                self.command = text
                reply = f"LUDUS_AGEING_BEFORE=30000\r\nLUDUS_AGEING={self.ageing}\r\n".encode()
                conn.sendall(server_frame(reply))


def run(ageing: str) -> tuple[int | str, FakeProxmox]:
    import subprocess

    server = FakeProxmox(ageing)
    script = Path(__file__).resolve().parents[1] / "files" / "set_bridge_ageing.py"
    env = os.environ.copy()
    env["LUDUS_SO_PVE_AUTH"] = "PVEAPIToken=root@pam!ludus-token=secret"
    env["LUDUS_SO_PVE_URL"] = f"http://127.0.0.1:{server.port}"
    env["LUDUS_SO_VMBR"] = "vmbr1004"
    env["LUDUS_SO_VM_NAMES"] = "so"
    env.pop("LUDUS_SO_PVE_NODE", None)
    proc = subprocess.run([str(script)], env=env, capture_output=True, text=True)
    if proc.returncode == 0:
        print(proc.stdout, end="")
        return 0, server
    detail = (proc.stderr or proc.stdout or f"exit {proc.returncode}").strip()
    return detail, server


def main() -> int:
    ok, server = run("0")
    try:
        if ok != 0:
            print(f"FAIL: expected success, got {ok}", file=sys.stderr)
            return 1
        if "echo 0 > /sys/class/net/vmbr1004/bridge/ageing_time" not in server.command:
            print(f"FAIL: console command was {server.command!r}", file=sys.stderr)
            return 1
    finally:
        server.close()
    print("PASS: hub mode set through the Proxmox console")

    bad, server = run("30000")
    try:
        if not isinstance(bad, str) or "30000" not in bad:
            print(f"FAIL: non-zero ageing should fail, got {bad!r}", file=sys.stderr)
            return 1
    finally:
        server.close()
    print("PASS: non-zero ageing fails the task")
    return 0


if __name__ == "__main__":
    sys.exit(main())

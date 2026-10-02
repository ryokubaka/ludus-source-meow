#!/usr/bin/env python3
"""Run the hub-mode script the way Ansible does: as an executable shebang."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "files" / "set_bridge_ageing.py"


def fail(msg: str) -> int:
    print(f"FAIL: {msg}", file=sys.stderr)
    return 1


def write_exec(path: Path, body: str) -> None:
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


def run_script(env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    merged = os.environ.copy()
    merged.update(env)
    return subprocess.run([str(SCRIPT)], env=merged, capture_output=True, text=True)


def test_shebang() -> int:
    raw = SCRIPT.read_bytes()
    if b"\r" in raw:
        return fail("set_bridge_ageing.py contains CR; the kernel would execute python3\\r")
    if not raw.startswith(b"#!/usr/bin/env python3\n"):
        return fail(f"shebang is {raw.splitlines()[0]!r}")
    proc = subprocess.run([str(SCRIPT)], capture_output=True, text=True)
    if proc.returncode == 127 or "python3\r" in (proc.stderr or ""):
        return fail(proc.stderr or "shebang failed")
    if "Need Proxmox URL" not in (proc.stderr or ""):
        return fail(f"missing-args run said {proc.stderr!r} / {proc.stdout!r}")
    print("PASS: shebang executes python3")
    return 0


def test_sudo() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        path = root / "class" / "net" / "vmbr1004" / "bridge"
        path.mkdir(parents=True)
        ageing = path / "ageing_time"
        ageing.write_text("30000\n")
        ageing.chmod(0o444)
        bindir = root / "bin"
        bindir.mkdir()
        write_exec(
            bindir / "sudo",
            "#!/bin/bash\n"
            "test \"$1\" = -n || exit 1\n"
            "shift\n"
            "test \"$1\" = tee || exit 1\n"
            "chmod u+w \"$2\"\n"
            "cat > \"$2\"\n",
        )
        write_exec(bindir / "ssh", "#!/bin/bash\necho ssh-should-not-run >&2\nexit 255\n")
        proc = run_script(
            {
                "PATH": f"{bindir}:{os.environ.get('PATH', '')}",
                "LUDUS_SO_PVE_AUTH": "token",
                "LUDUS_SO_PVE_URL": "https://minipve:8006",
                "LUDUS_SO_VMBR": "vmbr1004",
                "LUDUS_SO_SYSFS_ROOT": str(root),
            }
        )
        if proc.returncode != 0:
            return fail(proc.stderr or proc.stdout)
        if "method=sudo" not in proc.stdout or "ageing=0" not in proc.stdout:
            return fail(proc.stdout)
        if ageing.read_text().strip() != "0":
            return fail(f"sysfs is {ageing.read_text()!r}")
        if "ssh-should-not-run" in (proc.stderr or ""):
            return fail("ssh ran even though sudo -n worked")
    print("PASS: sudo -n sets ageing without SSH")
    return 0


def test_ssh() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        bindir = root / "bin"
        bindir.mkdir()
        log = root / "ssh.log"
        write_exec(
            bindir / "ssh",
            "#!/bin/bash\n"
            f"printf '%s\\n' \"$*\" >> {log}\n"
            "case \"$*\" in\n"
            "  *root@127.0.0.1*) echo LUDUS_AGEING_BEFORE=30000; echo LUDUS_AGEING=0; exit 0;;\n"
            "  *) exit 255;;\n"
            "esac\n",
        )
        proc = run_script(
            {
                "PATH": f"{bindir}:{os.environ.get('PATH', '')}",
                "LUDUS_SO_PVE_AUTH": "token",
                "LUDUS_SO_PVE_URL": "https://10.1.1.1:8006",
                "LUDUS_SO_VMBR": "vmbr1004",
                "LUDUS_SO_PVE_NODE": "minipve",
                "LUDUS_SO_SYSFS_ROOT": str(root / "missing"),
            }
        )
        if proc.returncode != 0:
            return fail(proc.stderr or proc.stdout)
        if "method=ssh:127.0.0.1" not in proc.stdout:
            return fail(proc.stdout)
        logged = log.read_text()
        if "root@127.0.0.1" not in logged or "vmbr1004" not in logged or "echo 0 >" not in logged:
            return fail(logged)
        if "termproxy" in logged or "vncwebsocket" in logged:
            return fail("still using the login console")
    print("PASS: root SSH sets ageing when the console would only show a login prompt")
    return 0


def test_all_fail() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        bindir = root / "bin"
        bindir.mkdir()
        write_exec(bindir / "ssh", "#!/bin/bash\nexit 255\n")
        write_exec(bindir / "sudo", "#!/bin/bash\nexit 1\n")
        proc = run_script(
            {
                "PATH": f"{bindir}:{os.environ.get('PATH', '')}",
                "LUDUS_SO_PVE_AUTH": "token",
                "LUDUS_SO_PVE_URL": "https://minipve:8006",
                "LUDUS_SO_VMBR": "vmbr1004",
                "LUDUS_SO_PVE_NODE": "minipve",
                "LUDUS_SO_SYSFS_ROOT": str(root / "missing"),
            }
        )
        text = (proc.stderr or "") + (proc.stdout or "")
        if proc.returncode == 0 or "ageing=0" in proc.stdout:
            return fail(f"failure was reported as success: {text}")
        if "login prompt" not in text or "root SSH failed" not in text:
            return fail(text)
    print("PASS: missing root access fails instead of pretending the bridge is a hub")
    return 0


def test_already_hub() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        path = root / "class" / "net" / "vmbr1004" / "bridge"
        path.mkdir(parents=True)
        ageing = path / "ageing_time"
        ageing.write_text("0\n")
        bindir = root / "bin"
        bindir.mkdir()
        write_exec(bindir / "ssh", "#!/bin/bash\necho ssh-should-not-run >&2\nexit 255\n")
        proc = run_script(
            {
                "PATH": f"{bindir}:{os.environ.get('PATH', '')}",
                "LUDUS_SO_PVE_AUTH": "token",
                "LUDUS_SO_PVE_URL": "https://minipve:8006",
                "LUDUS_SO_VMBR": "vmbr1004",
                "LUDUS_SO_SYSFS_ROOT": str(root),
            }
        )
        if proc.returncode != 0 or "method=present" not in proc.stdout or "changed=no" not in proc.stdout:
            return fail(proc.stdout + proc.stderr)
        if "ssh-should-not-run" in (proc.stderr or ""):
            return fail("already-hub bridge still tried SSH")
    print("PASS: ageing 0 is left alone")
    return 0


def _make_bridge(root: Path, name: str, ageing: str, ports: list[str]) -> None:
    bridge = root / "class" / "net" / name
    (bridge / "bridge").mkdir(parents=True)
    ageing_file = bridge / "bridge" / "ageing_time"
    ageing_file.write_text(ageing + "\n")
    ageing_file.chmod(0o444)
    brif = bridge / "brif"
    brif.mkdir()
    for port in ports:
        (brif / port).write_text("")


class _ApiState:
    def __init__(self, root: Path, force_drop: bool) -> None:
        self.root = root
        self.force_drop = force_drop
        self.updates: dict[str, dict] = {}
        self.reloads = 0


def _api_handler(state: _ApiState) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt: str, *args: object) -> None:
            return

        def _json(self, code: int, payload: dict) -> None:
            raw = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self) -> None:  # noqa: N802
            path = self.path.split("?", 1)[0].rstrip("/")
            if path.endswith("/network"):
                self._json(
                    200,
                    {
                        "data": [
                            {"iface": "vmbr1004", "type": "bridge"},
                            {
                                "iface": "vmbr0",
                                "type": "bridge",
                                "cidr": "10.9.9.1/24",
                                "gateway": "10.9.9.254",
                            },
                            {"iface": "nic0", "type": "eth"},
                        ]
                    },
                )
                return
            if "/tasks/" in path:
                self._json(200, {"data": {"status": "stopped", "exitstatus": "OK"}})
                return
            self._json(404, {"errors": path})

        def do_PUT(self) -> None:  # noqa: N802
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}")
            path = self.path.split("?", 1)[0].rstrip("/")
            if path.endswith("/network/vmbr1004") or path.endswith("/network/vmbr0"):
                state.updates[path.rsplit("/", 1)[-1]] = body
                self._json(200, {"data": None})
                return
            if path.endswith("/network"):
                state.reloads += 1
                self._apply()
                self._json(200, {"data": "UPID:minipve:001:reload"})
                return
            self._json(404, {"errors": path})

        def _apply(self) -> None:
            expected = {
                "vmbr1004": {"hub": True, "cidr": None},
                "vmbr0": {"hub": False, "cidr": "10.9.9.1/24"},
            }
            for name, cfg in expected.items():
                update = state.updates.get(name) or {}
                ovs = str(update.get("ovs_options") or "")
                safe = (
                    not state.force_drop
                    and "\n\tbridge-ports-condone-regex " in ovs
                    and update.get("bridge_ports") in (None, "")
                    and update.get("type") == "bridge"
                    and ("\n\tbridge-ageing 0" in ovs) == cfg["hub"]
                    and (cfg["cidr"] is None or update.get("cidr") == cfg["cidr"])
                    and (cfg["cidr"] is None or update.get("gateway") == "10.9.9.254")
                    and (cfg["cidr"] is None or "address" not in update)
                )
                brif = state.root / "class" / "net" / name / "brif"
                ageing = state.root / "class" / "net" / name / "bridge" / "ageing_time"
                if not safe:
                    for child in list(brif.iterdir()):
                        child.unlink()
                    continue
                if cfg["hub"]:
                    ageing.chmod(0o644)
                    ageing.write_text("0\n")

    return Handler


def _run_api(root: Path, force_drop: bool = False, condone: bool = True):
    _make_bridge(root, "vmbr1004", "30000", ["tap101i0"])
    _make_bridge(root, "vmbr0", "30000", ["fwpr1p0"])
    bindir = root / "bin"
    bindir.mkdir()
    ifreload_log = root / "ifreload.log"
    write_exec(bindir / "sudo", "#!/bin/bash\nexit 1\n")
    write_exec(bindir / "ssh", "#!/bin/bash\nexit 255\n")
    write_exec(bindir / "ifreload", f"#!/bin/bash\necho ifreload >> {ifreload_log}\nexit 0\n")
    addon = root / "bridge.py"
    addon.write_text("bridge-ports-condone-regex\n" if condone else "bridge ports only\n")
    state = _ApiState(root, force_drop)
    server = ThreadingHTTPServer(("127.0.0.1", 0), _api_handler(state))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        port = server.server_address[1]
        proc = run_script(
            {
                "PATH": f"{bindir}:{os.environ.get('PATH', '')}",
                "LUDUS_SO_PVE_AUTH": "PVEAPIToken=token",
                "LUDUS_SO_PVE_URL": f"http://10.1.1.1:{port}",
                "LUDUS_SO_VMBR": "vmbr1004",
                "LUDUS_SO_PVE_NODE": "minipve",
                "LUDUS_SO_SYSFS_ROOT": str(root),
                "LUDUS_SO_HTTP_TIMEOUT": "5",
                "LUDUS_SO_IFUPDOWN_BRIDGE": str(addon),
            }
        )
        return proc, state, ifreload_log
    finally:
        server.shutdown()


def test_api_keeps_other_bridges() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        proc, state, ifreload_log = _run_api(root)
        if proc.returncode != 0:
            return fail(proc.stderr or proc.stdout)
        if "method=api" not in proc.stdout or "ageing=0" not in proc.stdout:
            return fail(proc.stdout)
        ageing = (root / "class" / "net" / "vmbr1004" / "bridge" / "ageing_time").read_text().strip()
        other = (root / "class" / "net" / "vmbr0" / "bridge" / "ageing_time").read_text().strip()
        ports = {
            "vmbr1004": sorted(path.name for path in (root / "class/net/vmbr1004/brif").iterdir()),
            "vmbr0": sorted(path.name for path in (root / "class/net/vmbr0/brif").iterdir()),
        }
        if ageing != "0" or other != "30000":
            return fail(f"ageing target={ageing} other={other}")
        if ports != {"vmbr1004": ["tap101i0"], "vmbr0": ["fwpr1p0"]}:
            return fail(f"ports {ports}")
        if set(state.updates) != {"vmbr1004", "vmbr0"} or state.reloads != 1:
            return fail(f"updates={state.updates} reloads={state.reloads}")
        if ifreload_log.exists():
            return fail("local ifreload ran; the reload has to go through the API")
        if "nic0" in state.updates:
            return fail("updated a non-bridge")
    print("PASS: API reload hubs one bridge and keeps the other bridge's tap and address")
    return 0


def test_api_drop_fails() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        proc, state, _log = _run_api(Path(tmp), force_drop=True)
        text = (proc.stdout or "") + (proc.stderr or "")
        if proc.returncode == 0 or "ageing=0" in (proc.stdout or ""):
            return fail(f"dropped ports were reported as hub mode: {text}")
        if "Bridge ports removed" not in text or "tap101i0" not in text:
            return fail(text)
        if state.reloads != 1:
            return fail("expected the reload so the port check can fail closed")
    print("PASS: a reload that removes bridge ports fails closed")
    return 0


def test_no_ifreload() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        path = root / "class" / "net" / "vmbr1004" / "bridge"
        path.mkdir(parents=True)
        ageing = path / "ageing_time"
        ageing.write_text("30000\n")
        ageing.chmod(0o444)
        bindir = root / "bin"
        bindir.mkdir()
        log = root / "ifreload.log"
        write_exec(bindir / "sudo", "#!/bin/bash\nexit 1\n")
        write_exec(bindir / "ssh", "#!/bin/bash\nexit 255\n")
        write_exec(
            bindir / "ifreload",
            "#!/bin/bash\n"
            f"echo ifreload >> {log}\n"
            "exit 0\n",
        )
        addon = root / "bridge.py"
        addon.write_text("no condone option\n")
        proc = run_script(
            {
                "PATH": f"{bindir}:{os.environ.get('PATH', '')}",
                "LUDUS_SO_PVE_AUTH": "token",
                "LUDUS_SO_PVE_URL": "https://minipve:8006",
                "LUDUS_SO_VMBR": "vmbr1004",
                "LUDUS_SO_PVE_NODE": "minipve",
                "LUDUS_SO_SYSFS_ROOT": str(root),
                "LUDUS_SO_IFUPDOWN_BRIDGE": str(addon),
            }
        )
        text = (proc.stdout or "") + (proc.stderr or "")
        if proc.returncode == 0 or "ageing=0" in (proc.stdout or ""):
            return fail(f"unwritable sysfs was reported as hub mode: {text}")
        if log.exists():
            return fail("ifreload ran; that detaches VM taps on other ranges")
        if ageing.read_text().strip() != "30000":
            return fail(f"sysfs changed to {ageing.read_text()!r}")
        if "bridge-ports-condone-regex" not in text or "not reloaded" not in text:
            return fail(text)
    print("PASS: networking stays up when ifupdown2 cannot keep VM taps")
    return 0


def main() -> int:
    for test in (
        test_shebang,
        test_sudo,
        test_ssh,
        test_all_fail,
        test_already_hub,
        test_api_keeps_other_bridges,
        test_api_drop_fails,
        test_no_ifreload,
    ):
        rc = test()
        if rc:
            return rc
    return 0


if __name__ == "__main__":
    sys.exit(main())

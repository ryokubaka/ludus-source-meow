#!/usr/bin/env python3
"""Run the hub-mode script the way Ansible does: as an executable shebang."""

from __future__ import annotations

import os
import stat
import subprocess
import sys
import tempfile
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


def main() -> int:
    for test in (test_shebang, test_sudo, test_ssh, test_all_fail):
        rc = test()
        if rc:
            return rc
    return 0


if __name__ == "__main__":
    sys.exit(main())

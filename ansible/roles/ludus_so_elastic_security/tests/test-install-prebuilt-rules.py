#!/usr/bin/env python3
"""Prebuilt rule install retries an empty Kibana reply and installs in chunks."""

from __future__ import annotations

import json
import os
import socket
import stat
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "files" / "install-prebuilt-rules.sh"


def fail(msg: str) -> int:
    print(f"FAIL: {msg}", file=sys.stderr)
    return 1


class State:
    def __init__(self) -> None:
        self.drops = 1
        self.installed: list[dict] = []
        self.perform_modes: list[str] = []
        self.remaining = [
            {"rule_id": "rule-a", "version": 1},
            {"rule_id": "rule-b", "version": 3},
        ]


def handler_for(state: State):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt: str, *args) -> None:
            return

        def _json(self, code: int, payload: dict) -> None:
            raw = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def _read(self) -> dict:
            length = int(self.headers.get("Content-Length") or "0")
            if length == 0:
                return {}
            return json.loads(self.rfile.read(length))

        def do_GET(self) -> None:
            path = self.path.split("?", 1)[0]
            if path == "/api/status":
                self._json(200, {"status": {"overall": {"level": "available"}}})
                return
            if path == "/api/fleet/package_policies":
                self._json(200, {"items": []})
                return
            if path == "/api/fleet/epm/packages/security_detection_engine":
                self._json(200, {"item": {"latestVersion": "9.4.10"}})
                return
            if path == "/internal/detection_engine/prebuilt_rules/status":
                self._json(200, {"stats": {"num_prebuilt_rules_to_install": len(state.remaining)}})
                return
            self._json(404, {"message": path})

        def do_POST(self) -> None:
            body = self._read()
            path = self.path.split("?", 1)[0]
            if path == "/api/fleet/package_policies":
                self._json(200, {"item": {
                    "id": "pkg-1",
                    "name": body.get("name"),
                    "package": {"version": body.get("package", {}).get("version")},
                }})
                return
            if path.endswith("/installation/_review"):
                self._json(200, {
                    "page": 1,
                    "per_page": body.get("per_page", 100),
                    "total": len(state.remaining),
                    "rules": [
                        {"rule_id": item["rule_id"], "version": item["version"], "name": item["rule_id"]}
                        for item in state.remaining
                    ],
                    "stats": {"num_rules_to_install": len(state.remaining), "tags": []},
                })
                return
            if path.endswith("/installation/_perform"):
                if state.drops:
                    state.drops -= 1
                    self.connection.shutdown(socket.SHUT_WR)
                    return
                state.perform_modes.append(str(body.get("mode")))
                wanted = {(item["rule_id"], item["version"]) for item in body.get("rules") or []}
                state.installed.extend(body.get("rules") or [])
                state.remaining = [
                    item for item in state.remaining
                    if (item["rule_id"], item["version"]) not in wanted
                ]
                self._json(200, {"summary": {
                    "total": len(wanted),
                    "succeeded": len(wanted),
                    "skipped": 0,
                    "failed": 0,
                }, "results": {"created": [], "skipped": []}, "errors": []})
                return
            self._json(404, {"message": path})

    return Handler


def serve(state: State) -> tuple[ThreadingHTTPServer, str]:
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler_for(state))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address
    return server, f"http://{host}:{port}"


def test_shebang() -> int:
    raw = SCRIPT.read_bytes()
    if b"\r" in raw:
        return fail("script contains CR")
    if not raw.startswith(b"#!/bin/bash\n"):
        return fail(f"shebang {raw.splitlines()[0]!r}")
    print("PASS: prebuilt install script shebang")
    return 0


def test_retries_empty_reply_and_installs_chunks(tmp: Path) -> int:
    config = tmp / "curl.config"
    config.write_text('user = "elastic:secret"\n')
    state = State()
    server, url = serve(state)
    env = os.environ.copy()
    env.update({
        "LUDUS_SO_CURL_CONFIG": str(config),
        "LUDUS_SO_KIBANA_URL": url,
        "LUDUS_SO_KIBANA_WAIT": "2",
        "LUDUS_SO_RETRY_SLEEP": "0",
        "LUDUS_SO_AGENT_POLICY": "endpoints-initial",
        "LUDUS_SO_DETECTION_PACKAGE": "security_detection_engine",
        "LUDUS_SO_DETECTION_VERSION": "",
        "LUDUS_SO_RULE_CHUNK": "100",
    })
    try:
        proc = subprocess.run([str(SCRIPT)], env=env, capture_output=True, text=True)
    finally:
        server.shutdown()
    if proc.returncode != 0:
        return fail(f"rc={proc.returncode} out={proc.stdout!r} err={proc.stderr!r}")
    if "installed pkg-1 security_detection_engine-1 9.4.10" not in proc.stdout:
        return fail(f"package line {proc.stdout!r}")
    if "prebuilt_installed=2" not in proc.stdout or "prebuilt_failed=0" not in proc.stdout:
        return fail(f"summary {proc.stdout!r}")
    if state.perform_modes != ["SPECIFIC_RULES"]:
        return fail(f"modes {state.perform_modes}")
    if state.drops != 0:
        return fail("empty reply was not consumed")
    if state.remaining:
        return fail(f"remaining {state.remaining}")
    print("PASS: retries an empty reply and installs the review chunk")
    return 0


def main() -> int:
    if not os.access(SCRIPT, os.X_OK):
        SCRIPT.chmod(SCRIPT.stat().st_mode | stat.S_IEXEC)
    rc = test_shebang()
    if rc:
        return rc
    with tempfile.TemporaryDirectory() as tmp:
        return test_retries_empty_reply_and_installs_chunks(Path(tmp))


if __name__ == "__main__":
    raise SystemExit(main())

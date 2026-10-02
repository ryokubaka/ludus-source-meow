#!/usr/bin/env python3
"""Fleet policy helper: create FleetServer_<hostname> and attach fleet_server."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "files" / "ludus-so-ensure-fleet-policy"
HOST = "testhost"
POLICY = f"FleetServer_{HOST}"


def fail(msg: str) -> int:
    print(f"FAIL: {msg}", file=sys.stderr)
    return 1


class FleetState:
    def __init__(self) -> None:
        self.policy: dict | None = None
        self.integrations: list[dict] = [
            {
                "name": "fleet_server-FleetServer_manager",
                "policy_id": "FleetServer_manager",
                "enabled": True,
                "namespace": "default",
                "package": {"name": "fleet_server", "version": "1.6.1"},
                "inputs": [{"type": "fleet-server", "compiled_input": {"secret": True}, "streams": []}],
            }
        ]
        self.posts: list[str] = []
        self.puts: list[str] = []


def handler_for(state: FleetState):
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
                self._json(200, {"status": {"overall": {"level": "available"}}, "name": "fleet-server", "status": "HEALTHY"})
                return
            if path == "/api/fleet/outputs":
                self._json(200, {"items": [
                    {"id": "so-manager_logstash", "type": "logstash", "is_default": True},
                    {"id": "so-manager_elasticsearch", "type": "elasticsearch", "is_default": False},
                ]})
                return
            if path == f"/api/fleet/agent_policies/{POLICY}":
                if state.policy is None:
                    self._json(404, {"message": "missing"})
                else:
                    self._json(200, {"item": state.policy})
                return
            if path == "/api/fleet/package_policies":
                self._json(200, {"items": state.integrations})
                return
            self._json(404, {"message": path})

        def do_POST(self) -> None:
            body = self._read()
            state.posts.append(self.path)
            if self.path == "/api/fleet/agent_policies":
                state.policy = dict(body)
                self._json(200, {"item": state.policy})
                return
            if self.path == "/api/fleet/package_policies":
                if body.get("policy_id") != POLICY:
                    self._json(400, {"message": "wrong policy"})
                    return
                if "compiled_input" in json.dumps(body.get("inputs")):
                    self._json(400, {"message": "compiled_input"})
                    return
                state.integrations.append(body)
                self._json(200, {"item": body})
                return
            self._json(404, {"message": self.path})

        def do_PUT(self) -> None:
            body = self._read()
            state.puts.append(self.path)
            if self.path == f"/api/fleet/agent_policies/{POLICY}":
                state.policy = dict(state.policy or {}, **body)
                self._json(200, {"item": state.policy})
                return
            self._json(404, {"message": self.path})

    return Handler


def serve(state: FleetState) -> tuple[ThreadingHTTPServer, str]:
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler_for(state))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address
    return server, f"http://{host}:{port}"


def run(url: str, config: Path, extra: list[str]) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update({
        "LUDUS_SO_KIBANA_URL": url,
        "LUDUS_SO_FLEET_STATUS_URL": url + "/api/status",
        "LUDUS_SO_CURL_CONFIG": str(config),
        "LUDUS_SO_HOSTNAME": HOST,
        "LUDUS_SO_KIBANA_WAIT": "2",
        "LUDUS_SO_FLEET_TEMPLATE": "/no/such/fleet-server.json",
    })
    return subprocess.run([str(SCRIPT), *extra], env=env, capture_output=True, text=True)


def test_shebang() -> int:
    raw = SCRIPT.read_bytes()
    if b"\r" in raw:
        return fail("fleet helper contains CR")
    if not raw.startswith(b"#!/usr/bin/env python3\n"):
        return fail(f"shebang {raw.splitlines()[0]!r}")
    print("PASS: fleet helper shebang")
    return 0


def test_create_and_idempotent(tmp: Path) -> int:
    config = tmp / "curl.config"
    config.write_text('user = "elastic:secret"\n')
    state = FleetState()
    server, url = serve(state)
    try:
        first = run(url, config, ["--require-healthy"])
        if first.returncode != 0:
            return fail(f"create rc={first.returncode} {first.stdout} {first.stderr}")
        if "policy=created" not in first.stdout or "integration=created" not in first.stdout:
            return fail(f"create said {first.stdout!r}")
        if state.policy.get("data_output_id") != "so-manager_elasticsearch":
            return fail(f"output {state.policy}")
        if not state.puts:
            return fail("policy was not pointed at elasticsearch")
        second = run(url, config, ["--require-healthy"])
        if second.returncode != 0 or "policy=present" not in second.stdout or "integration=present" not in second.stdout:
            return fail(f"second run {second.returncode} {second.stdout!r}")
        if state.posts.count("/api/fleet/package_policies") != 1:
            return fail(f"integration posted {state.posts}")
    finally:
        server.shutdown()
    print("PASS: creates the hostname policy and stays quiet the next time")
    return 0


def test_best_effort_when_kibana_is_down(tmp: Path) -> int:
    config = tmp / "curl.config"
    config.write_text('user = "elastic:secret"\n')
    env = os.environ.copy()
    env.update({
        "LUDUS_SO_KIBANA_URL": "http://127.0.0.1:9",
        "LUDUS_SO_FLEET_STATUS_URL": "http://127.0.0.1:9/api/status",
        "LUDUS_SO_CURL_CONFIG": str(config),
        "LUDUS_SO_HOSTNAME": HOST,
        "LUDUS_SO_KIBANA_WAIT": "0",
    })
    proc = subprocess.run([str(SCRIPT), "--best-effort"], env=env, capture_output=True, text=True)
    if proc.returncode != 0 or "kibana=down" not in proc.stdout:
        return fail(f"best-effort {proc.returncode} {proc.stdout!r} {proc.stderr!r}")
    strict = subprocess.run([str(SCRIPT)], env=env, capture_output=True, text=True)
    if strict.returncode == 0:
        return fail("missing kibana exited 0 without --best-effort")
    print("PASS: best-effort exits 0 when Kibana is down")
    return 0


def main() -> int:
    if not os.access(SCRIPT, os.X_OK):
        SCRIPT.chmod(SCRIPT.stat().st_mode | stat.S_IEXEC)
    rc = test_shebang()
    if rc:
        return rc
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        rc = test_create_and_idempotent(root)
        if rc:
            return rc
        return test_best_effort_when_kibana_is_down(root)


if __name__ == "__main__":
    raise SystemExit(main())

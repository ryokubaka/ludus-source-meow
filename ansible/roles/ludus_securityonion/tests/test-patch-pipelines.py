#!/usr/bin/env python3
"""The pipeline loader keeps going when one PUT is not acknowledged yet."""

from __future__ import annotations

import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

PATCHER = Path(__file__).resolve().parents[1] / "files" / "patch_so_elasticsearch_pipelines.py"
sys.path.insert(0, str(PATCHER.parent))

from patch_so_elasticsearch_pipelines import LOOP_RE, patch_text  # noqa: E402

GUEST_LOOP = (
    '  echo "Loading pipelines..."\n'
    "  for i in *; \n"
    "  do \n"
    "    echo $i;\n"
    "    retry 5 5 \"so-elasticsearch-query _ingest/pipeline/$i -d@$i -XPUT "
    "| grep '{\\\"acknowledged\\\":true}'\" || fail \"Could not load pipeline: $i\"\n"
    "  done\n"
    "  echo\n"
    "  touch /opt/so/state/espipelines.txt\n"
)


def fail(msg: str) -> int:
    print(f"FAIL: {msg}", file=sys.stderr)
    return 1


def test_regex_matches_guest_loop() -> int:
    if not LOOP_RE.search(GUEST_LOOP):
        return fail("loader regex does not match the Security Onion loop")
    updated, status = patch_text(GUEST_LOOP)
    if status != "patched" or "ludus-pipeline-retry" not in updated:
        return fail(f"patch status {status}")
    if "retry 5 5" in updated:
        return fail("old retry remained")
    if "touch /opt/so/state/espipelines.txt" not in updated:
        return fail("patch ate the state file write")
    again, status = patch_text(updated)
    if status != "already-patched" or again != updated:
        return fail("second patch was not a no-op")
    print("PASS: patch matches the stock loader and is idempotent")
    return 0


def test_two_pass(tmp: Path) -> int:
    script = tmp / "so-elasticsearch-pipelines"
    script.write_text(
        "#!/bin/bash\n"
        "fail() { echo \"ERROR: $*\"; exit 1; }\n"
        "cd \"$1\"\n"
        + GUEST_LOOP
    )
    updated, status = patch_text(script.read_text())
    if status != "patched":
        return fail(status)
    script.write_text(updated)
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    bindir = tmp / "bin"
    bindir.mkdir()
    fake = bindir / "so-elasticsearch-query"
    calls = tmp / "calls"
    fake.write_text(
        "#!/bin/bash\n"
        "printf '%s\\n' \"$1\" >> \"$CALLS\"\n"
        "base=${1##*/}\n"
        "count=$(grep -c -F \"$1\" \"$CALLS\")\n"
        "if [[ \"$base\" == broken ]]; then echo '{\"error\":\"invalid\"}'; exit 22; fi\n"
        "if [[ \"$base\" == flaky && \"$count\" -lt 2 ]]; then echo '{\"error\":\"busy\"}'; exit 22; fi\n"
        "echo '{\"acknowledged\":true}'\n"
    )
    fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
    ingest = tmp / "ingest"
    ingest.mkdir()
    for name in ("broken", "flaky", "ok"):
        (ingest / name).write_text("{}\n")
    env = os.environ.copy()
    env.update({
        "PATH": f"{bindir}:{env.get('PATH', '')}",
        "CALLS": str(calls),
        "LUDUS_SO_PIPELINE_ATTEMPTS": "1",
        "LUDUS_SO_PIPELINE_SLEEP": "0",
    })
    proc = subprocess.run(["bash", str(script), str(ingest)], env=env, capture_output=True, text=True)
    log = calls.read_text() if calls.exists() else ""
    if proc.returncode == 0:
        return fail(f"broken pipeline was accepted\n{proc.stdout}")
    if "invalid" not in proc.stdout:
        return fail(f"error body was hidden\n{proc.stdout}\n{proc.stderr}")
    if log.count("_ingest/pipeline/ok") < 1:
        return fail(f"later pipeline was skipped\n{log}")
    if log.count("_ingest/pipeline/flaky") < 2:
        return fail(f"flaky pipeline was not retried on the second pass\n{log}")
    print("PASS: one rejected pipeline does not skip the rest")
    return 0


def main() -> int:
    raw = PATCHER.read_bytes()
    if b"\r" in raw:
        return fail("patcher contains CR")
    rc = test_regex_matches_guest_loop()
    if rc:
        return rc
    with tempfile.TemporaryDirectory() as tmp:
        return test_two_pass(Path(tmp))


if __name__ == "__main__":
    raise SystemExit(main())

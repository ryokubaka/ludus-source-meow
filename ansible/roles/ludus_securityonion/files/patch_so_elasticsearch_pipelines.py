#!/usr/bin/env python3
"""Give so-elasticsearch-pipelines time to ride out a busy boot cluster.

Salt deletes /opt/so/state/espipelines.txt on every highstate, then the loader
PUTs every ingest pipeline. It keeps the response only when grep sees the
compact string {"acknowledged":true}, and it gives up after five tries. During
boot that PUT often returns an error body for logs-pfsense.log-1.25.4, the
grep hides the body, and the failed state leaves the SOC grid in Fault.
"""

from __future__ import annotations

import pathlib
import re
import sys

MARKER = "ludus-pipeline-retry"

LOOP_RE = re.compile(
    r"^[ \t]*for i in \*;[ \t]*\n"
    r"(?:.*\n){0,12}?"
    r"^[ \t]*retry[ \t]+\d+[ \t]+\d+[ \t]+\"so-elasticsearch-query _ingest/pipeline/\$i[^\n]*\n"
    r"^[ \t]*done\n",
    re.M,
)


def replacement(indent: str) -> str:
    inner = indent + "  "
    return (
        f"{indent}# {MARKER}: a busy cluster during boot highstate returns an\n"
        f"{indent}# error body that grep discards. Retry, keep the body, and\n"
        f"{indent}# load every other pipeline before failing this one.\n"
        f"{indent}ludus_load_pipeline() {{\n"
        f"{inner}local name=\"$1\"\n"
        f"{inner}local attempt=0\n"
        f"{inner}local body=\"\"\n"
        f"{inner}local attempts=\"${{LUDUS_SO_PIPELINE_ATTEMPTS:-30}}\"\n"
        f"{inner}local delay=\"${{LUDUS_SO_PIPELINE_SLEEP:-5}}\"\n"
        f"{inner}while [ \"$attempt\" -lt \"$attempts\" ]; do\n"
        f"{inner}  attempt=$((attempt + 1))\n"
        f"{inner}  body=$(so-elasticsearch-query \"_ingest/pipeline/${{name}}\" -d@\"${{name}}\" -XPUT 2>/dev/null || true)\n"
        f"{inner}  if printf '%s' \"$body\" | grep -q '\"acknowledged\"[[:space:]]*:[[:space:]]*true'; then\n"
        f"{inner}    return 0\n"
        f"{inner}  fi\n"
        f"{inner}  echo \"pipeline ${{name}} attempt ${{attempt}}: ${{body}}\"\n"
        f"{inner}  if [ \"$attempt\" -lt \"$attempts\" ]; then\n"
        f"{inner}    sleep \"$delay\"\n"
        f"{inner}  fi\n"
        f"{inner}done\n"
        f"{inner}return 1\n"
        f"{indent}}}\n"
        f"{indent}ludus_failed=\"\"\n"
        f"{indent}for i in *; do\n"
        f"{inner}echo \"$i\"\n"
        f"{inner}if ! ludus_load_pipeline \"$i\"; then\n"
        f"{inner}  ludus_failed=\"${{ludus_failed}} ${{i}}\"\n"
        f"{inner}fi\n"
        f"{indent}done\n"
        f"{indent}ludus_still=\"\"\n"
        f"{indent}for i in ${{ludus_failed}}; do\n"
        f"{inner}echo \"retry $i\"\n"
        f"{inner}if ! ludus_load_pipeline \"$i\"; then\n"
        f"{inner}  ludus_still=\"${{ludus_still}} ${{i}}\"\n"
        f"{inner}fi\n"
        f"{indent}done\n"
        f"{indent}if [ -n \"${{ludus_still}}\" ]; then\n"
        f"{inner}fail \"Could not load pipeline:${{ludus_still}}\"\n"
        f"{indent}fi\n"
    )


def patch_text(text: str) -> tuple[str, str]:
    if MARKER in text:
        return text, "already-patched"
    match = LOOP_RE.search(text)
    if not match:
        return text, "pattern-not-found"
    indent = re.match(r"[ \t]*", match.group(0)).group(0)
    updated = text[: match.start()] + replacement(indent) + text[match.end() :]
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
        print("usage: patch_so_elasticsearch_pipelines.py PATH...", file=sys.stderr)
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

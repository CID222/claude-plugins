#!/usr/bin/env python3
"""PostToolUse redactor. Reads the hook JSON on stdin, inspects the tool's
primary text output via CID /inspect/v1 (through cid-common.sh, so auth/context
have one implementation), and on a REDACT verdict substitutes the redacted text
back into that same field — preserving the tool's output shape. Log-only rules
return ALLOW and are simply recorded. See docs/CLAUDE_CODE_BUILD_PLAN.md."""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def locate(resp):
    """Return (get, set) for the tool's primary text field, shape-preserving.
    A None setter means the whole response is the string to replace."""
    if isinstance(resp, str):
        return (lambda: resp, None)
    if isinstance(resp, dict):
        if isinstance(resp.get("stdout"), str):  # Bash
            return (lambda: resp["stdout"],
                    lambda t: resp.__setitem__("stdout", t))
        f = resp.get("file")
        if isinstance(f, dict) and isinstance(f.get("content"), str):  # Read
            return (lambda: f["content"],
                    lambda t: f.__setitem__("content", t))
        if isinstance(resp.get("content"), str):  # generic
            return (lambda: resp["content"],
                    lambda t: resp.__setitem__("content", t))
    return (None, None)


def cid_inspect(text, session_id=""):
    """Inspect `text` via the shared shell helper; return the verdict JSON str.
    session_id comes from the hook payload (Claude Code does not export
    CLAUDE_SESSION_ID to hooks) and rides to the helper as CID_SESSION_ID so
    the ctx-file lookup and telemetry both use the real session."""
    env = dict(os.environ)
    if session_id:
        env["CID_SESSION_ID"] = session_id
    try:
        out = subprocess.run(
            ["sh", "-c",
             '. "$1/cid-common.sh"; cid_inspect response "$2" tool_use',
             "_", HERE, text],
            capture_output=True, text=True, env=env,
            timeout=int(os.environ.get("CID_INSPECT_TIMEOUT", "6")),
        )
        return out.stdout.strip()
    except Exception:
        return ""


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    resp = data.get("tool_response")
    get, setf = locate(resp)
    if get is None:
        return
    text = get()
    if not text or not text.strip():
        return

    session_id = str(data.get("session_id") or "")
    verdict_json = cid_inspect(text, session_id)
    if not verdict_json:
        return  # fail-open: tool already ran locally; leave output as-is
    try:
        v = json.loads(verdict_json)
    except Exception:
        return
    if v.get("verdict") != "REDACT" or not isinstance(v.get("redactedPayload"), str):
        return  # ALLOW (incl. flag/log-only) — nothing to substitute

    redacted = v["redactedPayload"]
    updated = redacted if setf is None else (setf(redacted) or resp)
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "updatedToolOutput": updated,
        "additionalContext": "CID DLP redacted sensitive values in this tool "
                             "output before you received them.",
    }}))


if __name__ == "__main__":
    main()

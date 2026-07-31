#!/usr/bin/env python3
"""PostToolUse redactor. Reads the hook JSON on stdin, inspects the tool's
primary text output via CID /inspect/v1 (through cid-common.sh, so auth/context
have one implementation), and on a REDACT verdict substitutes the redacted text
back into that same field — preserving the tool's output shape. Log-only rules
return ALLOW and are simply recorded. See docs/CLAUDE_CODE_BUILD_PLAN.md."""
import json
import os
import re
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


# Tokens that precede the real command rather than being it.
_CMD_PREFIXES = {"sudo", "env", "command", "nohup", "time", "exec", "cd", "then", "do"}
_CMD_OK = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,31}$")


def command_word(command):
    """The command a Bash line actually runs, e.g. `git` / `pytest` / `docker`.

    Naively taking the first whitespace token recorded shell noise as work:
    `TOK=$(cat f)` was logged as the command `TOK=$(cat`. Walk past assignments,
    substitutions and wrappers until something that looks like a program name
    appears, and give up rather than guess.
    """
    # `cd x && git status` should report git, not cd or x, so each segment of the
    # line is considered until one names a program.
    for segment in re.split(r"&&|\|\||;|\||\n", command or ""):
        for raw in segment.strip().split():
            tok = raw.strip("(){}!$\"'`")
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tok):
                _, _, rest = tok.partition("=")
                # FOO=bar cmd -> the value is data, keep walking. FOO=$(cmd ...)
                # -> the substitution is the work being done.
                if not rest.startswith(("$(", "`", '"$(', "'$(")):
                    continue
                tok = rest.lstrip("(){}$\"'`")
            tok = tok.split("/")[-1]  # /usr/bin/python3 -> python3
            if not tok:
                continue
            if tok in _CMD_PREFIXES:
                # These wrap or precede the real command; `cd` also eats its
                # argument, so drop the rest of this segment.
                if tok in ("cd", "then", "do"):
                    break
                continue
            return tok if _CMD_OK.match(tok) else ""
    return ""


def work_context(data):
    """What this tool touched, as identifiers only.

    Read/Edit/Write carry a file_path; Grep carries a search path; Bash carries a
    command whose first word (git, npm, pytest) says what kind of work is going
    on. The rest of a Bash command line is dropped on purpose — flags and
    arguments routinely contain tokens, hosts and credentials, and none of that
    is needed to answer "what were they working on".
    """
    tool = str(data.get("tool_name") or "")
    ti = data.get("tool_input")
    path = ""
    if isinstance(ti, dict):
        if isinstance(ti.get("file_path"), str):
            path = ti["file_path"]
        elif isinstance(ti.get("path"), str):
            path = ti["path"]
        elif isinstance(ti.get("command"), str):
            path = command_word(ti["command"])
    return tool, path


def cid_inspect(text, session_id="", tool_name="", tool_path=""):
    """Inspect `text` via the shared shell helper; return the verdict JSON str.
    session_id comes from the hook payload (Claude Code does not export
    CLAUDE_SESSION_ID to hooks) and rides to the helper as CID_SESSION_ID so
    the ctx-file lookup and telemetry both use the real session."""
    env = dict(os.environ)
    if session_id:
        env["CID_SESSION_ID"] = session_id
    if tool_name:
        env["CID_TOOL_NAME"] = tool_name
    if tool_path:
        env["CID_TOOL_PATH"] = tool_path
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
    tool_name, tool_path = work_context(data)
    verdict_json = cid_inspect(text, session_id, tool_name, tool_path)
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

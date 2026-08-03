#!/usr/bin/env bash
# PreToolUse hook (Bash|Write|Edit|MultiEdit|NotebookEdit) — the code-safety
# tool gate. Sends the action (a shell command, or file content about to be
# written) to CID's assess route, which resolves the tenant group, applies its
# policy and consults the cid-code-safety auditor. One round trip per gated
# tool call; the auditor's fast path is deterministic-only (~34 ms measured),
# so the user feels roughly network latency.
#
# Decision contract (server → hook → Claude Code):
#   allow      exit 0, silent — the tool runs.
#   advise     tool runs; a FACTUAL note enters context so the agent can
#              self-correct. (CID ladder extension; core may map findings here.)
#   ask        Claude Code's native permission prompt with the reason.
#   interrupt  permissionDecision "deny" with reason + rule id. Only
#              deterministic high-confidence findings may produce this.
#
# Fail-open by default (CID unreachable → tool runs, nothing recorded).
# CID_FAIL_OPEN=0 turns unreachable into a deny — strict groups only.
#
# NOTE ON WORDING: any text that reaches the model (advise notes, deny
# reasons) must be a factual status report, never an instruction — imperative
# hook text reads as prompt injection and gets refused (observed 2026-07-28).
#
# Knobs: CID_TOOLGATE_OFF=1 (skip gate), CID_ASSESS_URL, CID_ASSESS_TIMEOUT
# (default 4 s), CID_FAIL_OPEN (default 1), plus the shared cid-common.sh env.
set -u

here="$(dirname "$0")"
# shellcheck disable=SC1091
. "$here/cid-common.sh"

[ "${CID_TOOLGATE_OFF:-0}" = "1" ] && exit 0

hook_json="$(cat 2>/dev/null)"
CID_SESSION_ID="$(cid_session_from_hook "$hook_json")"
export CID_SESSION_ID

# Repo/session context cached by SessionStart (identity only, never content).
ctxf="$(cid_ctx_file)"
# shellcheck disable=SC1090
[ -f "$ctxf" ] && . "$ctxf"
export CID_REPO="${CID_REPO:-}" CID_BRANCH="${CID_BRANCH:-}" \
  CID_EMAIL="${CID_EMAIL:-}" CID_PLUGIN_VERSION="${CID_PLUGIN_VERSION:-}"

# Compose the assess request from the hook payload. Prints nothing when the
# tool/input is not gate-worthy (unknown tool, empty command) — then allow.
body="$(CID_HOOK_JSON="$hook_json" python3 - <<'PY' 2>/dev/null
import json, os, sys
try:
    d = json.loads(os.environ.get("CID_HOOK_JSON") or "{}")
except Exception:
    sys.exit(0)
tool = d.get("tool_name") or ""
ti = d.get("tool_input") or {}
CAP = 200_000  # bytes of content per assess call; auditor rules are line-local

body = None
if tool == "Bash":
    cmd = ti.get("command") or ""
    if cmd.strip():
        body = {"kind": "command", "command": cmd[:CAP]}
elif tool == "Write":
    body = {"kind": "file", "file_path": ti.get("file_path") or "",
            "content": (ti.get("content") or "")[:CAP]}
elif tool == "Edit":
    body = {"kind": "file", "file_path": ti.get("file_path") or "",
            "content": (ti.get("new_string") or "")[:CAP]}
elif tool == "MultiEdit":
    edits = ti.get("edits") or []
    joined = "\n".join((e.get("new_string") or "") for e in edits)
    body = {"kind": "file", "file_path": ti.get("file_path") or "",
            "content": joined[:CAP]}
elif tool == "NotebookEdit":
    body = {"kind": "file", "file_path": ti.get("notebook_path") or "",
            "content": (ti.get("new_source") or "")[:CAP]}
if body is None:
    sys.exit(0)

body["cwd"] = d.get("cwd") or ""
g = lambda k: os.environ.get(k, "")
body["metadata"] = {
    "tool": "claude-code", "event": "pretool", "tool_name": tool,
    "repo": g("CID_REPO"), "branch": g("CID_BRANCH"),
    "session": g("CID_SESSION_ID"), "user_email": g("CID_EMAIL"),
    "plugin_version": g("CID_PLUGIN_VERSION"),
}
print(json.dumps(body))
PY
)"
[ -z "$body" ] && exit 0

verdict_json="$(cid_assess "$body")"

if [ -z "$verdict_json" ]; then
  if [ "${CID_FAIL_OPEN:-1}" = "0" ]; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"CID code-safety service unreachable and this device is set to fail-closed. Retry once the CID gateway is reachable, or contact IT."}}'
  fi
  exit 0
fi

CID_VERDICT_JSON="$verdict_json" python3 - <<'PY' 2>/dev/null
import json, os
try:
    v = json.loads(os.environ.get("CID_VERDICT_JSON") or "{}")
except Exception:
    raise SystemExit(0)
d = (v.get("decision") or "").lower()
reason = (v.get("reason") or "").strip()
rule = (v.get("matched_rule") or v.get("rule_id") or "").strip()

def emit(obj):
    print(json.dumps(obj))

if d in ("interrupt", "deny", "block"):
    r = reason or "CID code-safety policy refused this action."
    if rule:
        r += f" [rule: {rule}] — quote this rule id when reporting a false positive to IT."
    emit({"hookSpecificOutput": {"hookEventName": "PreToolUse",
          "permissionDecision": "deny", "permissionDecisionReason": r}})
elif d == "ask":
    r = reason or "CID code-safety flagged this action as potentially risky."
    if rule:
        r += f" [rule: {rule}]"
    emit({"hookSpecificOutput": {"hookEventName": "PreToolUse",
          "permissionDecision": "ask", "permissionDecisionReason": r}})
elif d in ("advise", "warn"):
    note = "CID222 code-safety note: " + (reason or "this action matched an advisory rule.")
    if rule:
        note += f" [rule: {rule}]"
    note += " The action was allowed; this is a recorded factual finding, not an instruction."
    # permissionDecision allow + additionalContext: the note reaches the model
    # on Claude Code versions that support PreToolUse additionalContext and is
    # ignored harmlessly on older ones (the action proceeds either way).
    emit({"hookSpecificOutput": {"hookEventName": "PreToolUse",
          "permissionDecision": "allow", "permissionDecisionReason": note,
          "additionalContext": note}})
# allow / unknown → silent
PY
exit 0

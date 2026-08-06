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
# A LOCAL deterministic gate runs first (no network). It covers, for commands:
# destructive SQL (DROP/TRUNCATE/WHERE-less DELETE|UPDATE/GRANT ALL), destructive
# filesystem (rm -rf, dd, mkfs, shred, wipefs, chmod -R 777, fork bomb), git
# history rewrite (force push, reset --hard, clean -f), remote-code/supply-chain
# (curl|sh, eval/interp of downloads, iex, pip-from-url, insecure npm registry),
# disabled TLS/host-key verification, infra destruction (kubectl/terraform/helm/
# docker prune), persistence & system tampering (shell rc, crontab, /etc, sudoers,
# firewall/SELINUX off), and secret exfiltration — all → native "ask". For file
# writes: hardcoded secrets (AWS/GitHub/Slack/Anthropic/Google/OpenAI keys,
# private keys) → ask; insecure-code patterns + CI/Docker footguns → advise. This
# makes the gate meaningful even where the /assess route isn't deployed yet; when
# it is, the server verdict layers on top for everything the local rules miss.
#
# Knobs: CID_TOOLGATE_OFF=1 (skip gate entirely), CID_LOCAL_GATE_OFF=1 (skip
# only the local deterministic rules, keep the server assess call),
# CID_ASSESS_URL, CID_ASSESS_TIMEOUT (default 4 s), CID_FAIL_OPEN (default 1),
# plus the shared cid-common.sh env.
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

# ---- Local deterministic high-risk gate (runs with NO backend) --------------
# Matches a short list of unambiguously destructive patterns in the command (or
# the file content about to be written) and, on a hit, emits a native "ask" so
# Claude Code shows its confirmation prompt with the reason. Deterministic and
# offline: the demo-safe floor beneath the server assess verdict.
if [ "${CID_LOCAL_GATE_OFF:-0}" != "1" ]; then
  local_out="$(CID_HOOK_JSON="$hook_json" python3 - <<'PY' 2>/dev/null
import json, os, re, sys
try:
    d = json.loads(os.environ.get("CID_HOOK_JSON") or "{}")
except Exception:
    sys.exit(0)
tool = d.get("tool_name") or ""
ti = d.get("tool_input") or {}
FILE_TOOLS = ("Write", "Edit", "MultiEdit", "NotebookEdit")
fpath = ""
if tool == "Bash":
    text = ti.get("command") or ""
elif tool in FILE_TOOLS:
    fpath = ti.get("file_path") or ti.get("notebook_path") or ""
    if tool == "Write":
        text = ti.get("content") or ""
    elif tool == "Edit":
        text = ti.get("new_string") or ""
    elif tool == "MultiEdit":
        text = "\n".join((e.get("new_string") or "") for e in (ti.get("edits") or []))
    else:
        text = ti.get("new_source") or ""
else:
    sys.exit(0)

raw = text or ""
flat = re.sub(r"\s+", " ", raw).strip()
low = flat.lower()
flow = fpath.lower()
if not flat:
    sys.exit(0)

ask, advise = [], []
def A(rid, why): ask.append((rid, why))
def V(rid, why): advise.append((rid, why))

if tool == "Bash":
    # --- SQL ---
    if re.search(r"\bdrop\s+(table|database|schema)\b", low): A("cc-sql-drop", "a DROP of a table, database or schema (irreversible)")
    if re.search(r"\btruncate\s+table\b", low): A("cc-sql-truncate", "a TRUNCATE, which removes every row in the table")
    if re.search(r"\bdelete\s+from\b", low) and " where " not in low: A("cc-sql-delete-all", "a DELETE with no WHERE clause — it deletes every row")
    if re.search(r"\bupdate\s+\S+\s+set\b", low) and " where " not in low: A("cc-sql-update-all", "an UPDATE with no WHERE clause — it rewrites every row")
    if re.search(r"\bgrant\s+all\b", low): A("cc-sql-grant-all", "a GRANT ALL — a broad privilege grant")
    # --- destructive filesystem ---
    if re.search(r"\brm\s+-[a-z]*r[a-z]*f|\brm\s+-[a-z]*f[a-z]*r", low): A("cc-rm-rf", "an rm -rf — a recursive, forced delete")
    if re.search(r"\bdd\s+if=", low): A("cc-dd", "a dd command, which can overwrite whole disks")
    if re.search(r"\bmkfs(\.\w+)?\b", low): A("cc-mkfs", "an mkfs, which formats a filesystem")
    if re.search(r"\bshred\b", low): A("cc-shred", "a shred — it irreversibly destroys file data")
    if re.search(r"\bwipefs\b", low): A("cc-wipefs", "a wipefs — it erases filesystem signatures")
    if re.search(r"\bchmod\s+-r\s+777\b", low): A("cc-chmod-777", "a chmod -R 777 — it makes a whole tree world-writable")
    if re.search(r":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:", flat): A("cc-forkbomb", "a shell fork bomb")
    # --- git history rewrite ---
    if re.search(r"\bgit\s+push\b[^;&|]*(--force\b|\s-f\b|--force-with-lease\b)", low): A("cc-git-force", "a git force push — it can overwrite shared history")
    if re.search(r"\bgit\s+reset\s+--hard\b", low): A("cc-git-reset", "a git reset --hard — it discards uncommitted work")
    if re.search(r"\bgit\s+clean\s+-[a-z]*f", low): A("cc-git-clean", "a git clean -f — it deletes untracked files")
    # --- remote code execution / supply chain ---
    if re.search(r"(curl|wget)\b[^|]*\|\s*(sudo\s+)?(bash|sh|zsh)\b", low): A("cc-pipe-shell", "a piped download run straight through a shell")
    if re.search(r"\beval\b[^;]*\$\(\s*(curl|wget)", low): A("cc-eval-remote", "eval of a downloaded script")
    if re.search(r"\b(python[0-9.]*|node|ruby|perl)\b[^;]*-e[^;]*\$\(\s*(curl|wget)", low): A("cc-interp-remote", "running a downloaded script through an interpreter")
    if re.search(r"\biwr\b[^|]*\|\s*iex\b|\biex\s*\(", low): A("cc-iex-remote", "PowerShell downloading and invoking a remote script")
    if re.search(r"\bpip[0-9]?\s+install\b[^;]*(http://|git\+)", low): A("cc-pip-untrusted", "a pip install from a URL / git source")
    if re.search(r"\bnpm\s+config\s+set\s+registry\s+http://", low): A("cc-npm-registry", "pointing npm at an insecure (http) registry")
    # --- TLS / verification disabled ---
    if re.search(r"(curl|wget)\b[^|]*(\s-k\b|--insecure\b|--no-check-certificate\b)", low): A("cc-tls-curl", "disabling TLS certificate verification on a download")
    if re.search(r"node_tls_reject_unauthorized\s*=\s*0", low): A("cc-tls-node", "disabling TLS verification (NODE_TLS_REJECT_UNAUTHORIZED=0)")
    if re.search(r"stricthostkeychecking[= ]no", low): A("cc-ssh-nohostkey", "disabling SSH host-key checking")
    # --- infra destruction ---
    if re.search(r"\bkubectl\s+delete\b", low): A("cc-k8s-delete", "a kubectl delete — it removes live cluster resources")
    if re.search(r"\bterraform\s+destroy\b", low): A("cc-tf-destroy", "a terraform destroy — it tears down provisioned infra")
    if re.search(r"\bdocker\s+system\s+prune\b[^;]*-a|\bdocker\s+system\s+prune\s+-a", low): A("cc-docker-prune", "a docker system prune -a — it removes all unused images/volumes")
    if re.search(r"\bhelm\s+(delete|uninstall)\b", low): A("cc-helm-delete", "a helm uninstall — it removes a deployed release")
    # --- persistence / system tampering ---
    if re.search(r">>?\s*~?/?(\.bashrc|\.zshrc|\.bash_profile|\.profile)\b", low): A("cc-persist-rc", "writing to a shell startup file (a persistence vector)")
    if re.search(r"\bcrontab\b|>\s*/etc/cron", low): A("cc-persist-cron", "installing a cron job (a persistence vector)")
    if re.search(r"(>|\btee\b)\s*/etc/|\bvisudo\b|/etc/sudoers", low): A("cc-etc-write", "writing to a system config under /etc")
    if re.search(r"\bufw\s+disable\b|\biptables\s+-f\b|\bsetenforce\s+0\b", low): A("cc-security-off", "disabling a host firewall / SELinux")
    # --- secret exfiltration ---
    if re.search(r"(curl|wget|nc|ncat)\b", low) and re.search(r"(\.env\b|id_rsa\b|\.aws/credentials|\.ssh/id|\.pgpass|\.netrc|\$[a-z_]*secret|\$[a-z_]*token|\$[a-z_]*password)", low): A("cc-exfil", "sending environment or credential data to a remote host")
    if re.search(r"\benv\b\s*\|\s*(curl|wget|nc)", low): A("cc-exfil", "piping the environment to a network command")
    # --- sensitive read (advise) ---
    if re.search(r"\b(cat|less|head|tail)\b[^|;]*(\.env\b|id_rsa\b|\.aws/credentials|\.ssh/id|\.pgpass|\.netrc)|/etc/shadow", low): V("cc-read-secret", "reading a secret / credentials file")
else:
    # ---- file content being written ----
    if re.search(r"AKIA[0-9A-Z]{16}", raw): A("cc-secret-aws", "an AWS access key id being written into a file")
    if re.search(r"-----BEGIN\s+[A-Z0-9 ]*PRIVATE KEY-----", raw): A("cc-secret-privkey", "a private key being written into a file")
    if re.search(r"\bghp_[A-Za-z0-9]{30,}", raw): A("cc-secret-ghp", "a GitHub token being written into a file")
    if re.search(r"\bxox[baprs]-[A-Za-z0-9-]{10,}", raw): A("cc-secret-slack", "a Slack token being written into a file")
    if re.search(r"\bsk-ant-[A-Za-z0-9_-]{20,}", raw): A("cc-secret-anthropic", "an Anthropic API key being written into a file")
    if re.search(r"\bAIza[0-9A-Za-z_-]{30,}", raw): A("cc-secret-google", "a Google API key being written into a file")
    if re.search(r"\bsk-[A-Za-z0-9]{32,}", raw): A("cc-secret-openai", "an OpenAI-style API key being written into a file")
    # insecure code patterns (advise)
    if re.search(r"verify\s*=\s*False\b", raw): V("cc-code-verify", "TLS verification disabled in code (verify=False)")
    if re.search(r"InsecureSkipVerify\s*:\s*true", raw): V("cc-code-tlsskip", "TLS verification disabled in code (InsecureSkipVerify)")
    if re.search(r"rejectUnauthorized\s*:\s*false", raw): V("cc-code-rejectunauth", "TLS verification disabled in code (rejectUnauthorized:false)")
    if re.search(r"dangerouslySetInnerHTML", raw): V("cc-code-xss", "dangerouslySetInnerHTML (a possible XSS sink)")
    if re.search(r"\beval\s*\(", raw): V("cc-code-eval", "an eval() call")
    if re.search(r"child_process\.exec\s*\(", raw): V("cc-code-exec", "child_process.exec (a possible command-injection sink)")
    if re.search(r"#\s*nosec\b", raw): V("cc-code-nosec", "a suppressed security check (# nosec)")
    if re.search(r"pickle\.loads?\s*\(", raw): V("cc-code-pickle", "pickle deserialization (an RCE risk)")
    # CI / supply-chain files (advise)
    if (re.search(r"\.github/workflows/", flow) or re.search(r"(^|/)dockerfile", flow)) and re.search(r"(curl|wget)[^|]*\|\s*(bash|sh)", low): V("cc-ci-pipe", "a piped-download-to-shell inside a CI / Docker build file")
    if re.search(r"privileged\s*:\s*true", raw): V("cc-k8s-priv", "a privileged: true container spec")

if not ask and not advise:
    sys.exit(0)
if ask:
    rid, why = ask[0]
    reason = ("CID222 code-safety flagged this: it looks like " + why + ". "
              "This is a factual notice; the confirmation below is Claude Code's own. "
              "[rule: " + rid + "]")
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "ask",
        "permissionDecisionReason": reason,
    }}))
else:
    notes = "; ".join(w for _, w in advise[:3])
    ids = ",".join(r for r, _ in advise[:3])
    note = ("CID222 code-safety note: " + notes + ". The action was allowed; "
            "this is a recorded factual finding, not an instruction. [rule: " + ids + "]")
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "permissionDecisionReason": note,
        "additionalContext": note,
    }}))
PY
)"
  if [ -n "$local_out" ]; then
    printf '%s\n' "$local_out"
    exit 0
  fi
fi

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

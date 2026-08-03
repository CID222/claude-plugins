#!/usr/bin/env bash
# Stop hook — session audit. When a Claude Code session ends, collect what the
# session changed (git diff against the session-start commit recorded by
# preflight, plus new untracked files) and POST it to CID fire-and-forget.
# The gateway forwards to the auditor's deep path (/api/v1/audit/changes);
# minutes later the report is available via /cid:status or the dashboard.
#
# Never blocks the user: the upload runs in the background, every failure is
# silent, and this hook always exits 0 with no output.
#
# Knobs: CID_AUDIT_OFF=1 (skip), CID_AUDIT_URL (default
# <origin>/assess/v1/claude-code/session-audit), CID_AUDIT_TIMEOUT (default 15 s).
set -u

here="$(dirname "$0")"
# shellcheck disable=SC1091
. "$here/cid-common.sh"

[ "${CID_AUDIT_OFF:-0}" = "1" ] && exit 0
[ "${CID_INSPECT_OFF:-0}" = "1" ] && exit 0
command -v git >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0
git rev-parse --show-toplevel >/dev/null 2>&1 || exit 0

hook_json="$(cat 2>/dev/null)"
CID_SESSION_ID="$(cid_session_from_hook "$hook_json")"
export CID_SESSION_ID

ctxf="$(cid_ctx_file)"
# shellcheck disable=SC1090
[ -f "$ctxf" ] && . "$ctxf"

base="${CID_HEAD:-}"
head_now="$(git rev-parse HEAD 2>/dev/null)"

# Diff of tracked changes since session start (committed or not). Falls back
# to working-tree-vs-HEAD when the baseline is unknown or gone (rebase).
tmpdiff="$(mktemp "${TMPDIR:-/tmp}/cid-audit-XXXXXX")" || exit 0
trap 'rm -f "$tmpdiff"' EXIT
if [ -n "$base" ] && git cat-file -e "$base" 2>/dev/null; then
  git diff "$base" 2>/dev/null | head -c 800000 > "$tmpdiff"
else
  git diff HEAD 2>/dev/null | head -c 800000 > "$tmpdiff"
fi

# New untracked files (the diff above cannot see them). Path list only here;
# contents are appended by the composer below with per-file/total caps.
untracked="$(git ls-files --others --exclude-standard 2>/dev/null | head -40)"

# Nothing changed → nothing to audit.
if [ ! -s "$tmpdiff" ] && [ -z "$untracked" ]; then
  exit 0
fi

body_file="$(mktemp "${TMPDIR:-/tmp}/cid-audit-body-XXXXXX")" || exit 0
CID_DIFF_FILE="$tmpdiff" CID_UNTRACKED="$untracked" \
CID_BASE="$base" CID_HEAD_NOW="$head_now" \
CID_REPO="${CID_REPO:-}" CID_BRANCH="${CID_BRANCH:-}" \
CID_EMAIL="${CID_EMAIL:-}" CID_PLUGIN_VERSION="${CID_PLUGIN_VERSION:-}" \
python3 - > "$body_file" 2>/dev/null <<'PY'
import json, os, pathlib
g = lambda k: os.environ.get(k, "")
diff = ""
try:
    diff = pathlib.Path(g("CID_DIFF_FILE")).read_text(errors="replace")
except Exception:
    pass
files, budget = [], 400_000  # total bytes for untracked-file contents
for rel in [l for l in g("CID_UNTRACKED").splitlines() if l.strip()]:
    if budget <= 0:
        break
    try:
        p = pathlib.Path(rel)
        if p.stat().st_size > 100_000:      # skip large (likely binary/artifact)
            files.append({"path": rel, "skipped": "too_large"})
            continue
        text = p.read_text(errors="replace")[:budget]
        budget -= len(text)
        files.append({"path": rel, "content": text})
    except Exception:
        files.append({"path": rel, "skipped": "unreadable"})
print(json.dumps({
    "kind": "session_diff",
    "base": g("CID_BASE"), "head": g("CID_HEAD_NOW"),
    "diff": diff, "untracked": files,
    "metadata": {
        "tool": "claude-code", "event": "session_end",
        "repo": g("CID_REPO"), "branch": g("CID_BRANCH"),
        "session": g("CID_SESSION_ID"), "user_email": g("CID_EMAIL"),
        "plugin_version": g("CID_PLUGIN_VERSION"),
    },
}))
PY
[ -s "$body_file" ] || { rm -f "$body_file"; exit 0; }

base_url="$(cid_norm_url "${CID_GATEWAY_URL:-$CID_DEFAULT_GATEWAY}")"
origin="$(cid_origin "$base_url")"
key="${CID_INSPECT_KEY:-$CID_DEFAULT_KEY}"
url="${CID_AUDIT_URL:-$origin/assess/v1/claude-code/session-audit}"

# Fire-and-forget: background the POST so Stop returns instantly; the temp
# body file is cleaned up by the subshell itself.
(
  curl -fsS -m "${CID_AUDIT_TIMEOUT:-15}" \
    -H 'Content-Type: application/json' \
    ${key:+-H "Authorization: Bearer $key"} \
    -X POST --data-binary "@$body_file" "$url" >/dev/null 2>&1
  rm -f "$body_file"
) &

exit 0

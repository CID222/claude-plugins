#!/usr/bin/env bash
# SessionStart hook (runs after preflight) — repo baseline audit.
#
# The first time ANYONE in the org starts Claude Code work in a repository,
# that repo gets one full deep-path audit. The server dedups by repo_id (a
# hash of the normalized git remote URL, so every clone of the same repo maps
# to the same id) — a second developer opening the same repo gets
# {"baseline_needed": false} and uploads nothing.
#
# Flow (all fail-silent, upload backgrounded so SessionStart is not delayed):
#   1. POST {repo_id, repo, branch, head}          → .../repo-baseline
#      server: {"baseline_needed": bool, "status"?, "summary"?}
#   2. if needed: git archive HEAD (tracked files only — respects .gitignore,
#      no secrets dirs that are properly ignored) | gzip → upload.
#   3. Emit a factual context note so the session knows a baseline exists /
#      was queued (never an instruction — see wording note in cid-preflight.sh).
#
# Knobs: CID_BASELINE_OFF=1 (skip), CID_BASELINE_URL (default
# <origin>/assess/v1/claude-code/repo-baseline), CID_BASELINE_MAX_MB
# (compressed upload cap, default 40), CID_BASELINE_TIMEOUT (upload, 120 s).
set -u

here="$(dirname "$0")"
# shellcheck disable=SC1091
. "$here/cid-common.sh"

[ "${CID_BASELINE_OFF:-0}" = "1" ] && exit 0
[ "${CID_INSPECT_OFF:-0}" = "1" ] && exit 0
command -v git >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0
root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -z "$root" ] && exit 0

hook_json="$(cat 2>/dev/null)"
CID_SESSION_ID="$(cid_session_from_hook "$hook_json")"
export CID_SESSION_ID

remote="$(git config --get remote.origin.url 2>/dev/null)"
remote="$(printf '%s' "$remote" | sed -E 's#(https?://)[^@/]*@#\1#')"
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
head="$(git rev-parse HEAD 2>/dev/null)"
[ -z "$head" ] && exit 0   # empty repo — nothing to audit

# repo_id: same repo → same id for every developer and every clone.
# Normalized remote URL when there is one; path basename fallback for
# remoteless repos (those dedup per-machine only, which is the best we can do).
repo_key="${remote:-local:$(basename "$root")}"
repo_id="$(printf '%s' "$repo_key" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:32])' 2>/dev/null)"
[ -z "$repo_id" ] && exit 0

base_url="$(cid_norm_url "${CID_GATEWAY_URL:-$CID_DEFAULT_GATEWAY}")"
origin="$(cid_origin "$base_url")"
key="${CID_INSPECT_KEY:-$CID_DEFAULT_KEY}"
url="${CID_BASELINE_URL:-$origin/assess/v1/claude-code/repo-baseline}"

check_body="$(CID_RID="$repo_id" CID_R="$remote" CID_B="$branch" CID_H="$head" \
  CID_S="${CID_SESSION_ID:-}" python3 -c 'import json,os
g=lambda k: os.environ.get(k,"")
print(json.dumps({"repo_id":g("CID_RID"),"repo":g("CID_R"),"branch":g("CID_B"),"head":g("CID_H"),"session":g("CID_S")}))' 2>/dev/null)"
[ -z "$check_body" ] && exit 0

resp="$(curl -fsS -m 5 \
  -H 'Content-Type: application/json' \
  ${key:+-H "Authorization: Bearer $key"} \
  -X POST -d "$check_body" "$url" 2>/dev/null)"
[ -z "$resp" ] && exit 0   # gateway/route unavailable → silently skip

needed="$(cid_json_field "$resp" baseline_needed)"
status="$(cid_json_field "$resp" status)"
summary="$(cid_json_field "$resp" summary)"

if [ "$needed" = "True" ] || [ "$needed" = "true" ]; then
  # First session on this repo org-wide: pack tracked files and upload in the
  # background. git archive HEAD honors .gitignore by construction.
  max_mb="${CID_BASELINE_MAX_MB:-40}"
  (
    tmp="$(mktemp "${TMPDIR:-/tmp}/cid-baseline-XXXXXX.tar.gz")" || exit 0
    if git archive --format=tar HEAD 2>/dev/null | gzip > "$tmp" 2>/dev/null; then
      size_kb="$(du -k "$tmp" 2>/dev/null | cut -f1)"
      if [ -n "$size_kb" ] && [ "$size_kb" -le "$((max_mb * 1024))" ]; then
        curl -fsS -m "${CID_BASELINE_TIMEOUT:-120}" \
          -H 'Content-Type: application/gzip' \
          ${key:+-H "Authorization: Bearer $key"} \
          -H "X-CID-Repo-Id: $repo_id" \
          -H "X-CID-Repo-Head: $head" \
          -X POST --data-binary "@$tmp" "$url/upload" >/dev/null 2>&1
      fi
    fi
    rm -f "$tmp"
  ) &
  printf '%s\n' "[CID] This repository has no CID code-safety baseline yet; the first full audit was queued from this session (runs server-side; results appear in /cid:status and the dashboard)."
elif [ -n "$summary" ]; then
  printf '%s\n' "[CID] CID code-safety baseline for this repository: $summary"
elif [ -n "$status" ]; then
  printf '%s\n' "[CID] CID code-safety baseline for this repository: $status."
fi

exit 0

#!/usr/bin/env bash
# CID222 preflight — SessionStart hook (macOS/Linux; Windows: cid-preflight.ps1).
# 1) Verifies this Claude Code session is routed through the CID gateway.
# 2) Emits a neutral status line as context + a user-visible warning on bypass.
# 3) Announces the session to CID (seat, repo, branch) so the fleet dashboard
#    sees it even in visibility-only mode, and so gateway token reports — which
#    carry only a session id — can be attributed to a person and a repository.
#
# NOTE ON WORDING: context output is a FACTUAL STATUS REPORT only. Never phrase
# it as an instruction to the model ("tell the user…", "do not suggest…") —
# models correctly treat imperative text arriving from a hook as a possible
# prompt injection and refuse to act on it (observed 2026-07-28). User-facing
# advice belongs on stderr, which Claude Code shows to the user directly.
#
# Env contract (set via managed settings "env" or user env):
#   CID_GATEWAY_URL    Expected gateway base URL. Scheme optional (https:// assumed).
#   CID_INSPECT_KEY    Overrides the baked inspection key (probe + hooks).
#   CID_TELEMETRY_OFF  1 = probe without identifying the session (no session row)
#   CID_PREFLIGHT_OFF  1 = skip everything (break-glass)
set -u

[ "${CID_PREFLIGHT_OFF:-0}" = "1" ] && exit 0

# Resolve the session id from the hook payload on stdin. Claude Code does NOT
# export CLAUDE_SESSION_ID to hook processes — every hook gets `session_id` in
# its stdin JSON instead. Without this, all concurrent sessions shared one
# "nosession" ctx file and overwrote each other's repo/branch.
here="$(dirname "$0")"
# shellcheck disable=SC1091
. "$here/cid-common.sh"
hook_json="$(cat 2>/dev/null)"
CID_SESSION_ID="$(cid_session_from_hook "$hook_json")"
export CID_SESSION_ID

# --- Cache the repo/session context once for the prompt & tool hooks ----------
# Identity only, never content: normalized git remote (credentials stripped),
# branch, repo-root basename, and the Claude seat email. ~3 ms, cached per
# session so the per-prompt hooks don't re-shell git.
cid_write_ctx() {
  command -v git >/dev/null 2>&1 || return 0
  local remote branch root cwdbase email tmpf ctxf
  remote="$(git config --get remote.origin.url 2>/dev/null)"
  # strip credentials embedded in the URL (https://user:tok@host/…)
  remote="$(printf '%s' "$remote" | sed -E 's#(https?://)[^@/]*@#\1#')"
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  root="$(git rev-parse --show-toplevel 2>/dev/null)"
  cwdbase="$(basename "${root:-$PWD}")"
  email=""
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && command -v python3 >/dev/null 2>&1; then
    email="$(python3 - <<'PY' 2>/dev/null || true
import json, pathlib
p = pathlib.Path.home() / ".claude.json"
try:
    print((json.loads(p.read_text()).get("oauthAccount") or {}).get("emailAddress") or "")
except Exception:
    pass
PY
)"
  fi
  # Is provider traffic routed through a gateway? When ANTHROPIC_BASE_URL points
  # somewhere other than Anthropic, a CID gateway is in the request path and can
  # rewrite the prompt — so the prompt hook must not tell the user masking is
  # impossible. Recorded here rather than re-derived per prompt.
  routed=0
  case "${ANTHROPIC_BASE_URL:-}" in
    ''|*api.anthropic.com*) : ;;
    *) routed=1 ;;
  esac

  ctxf="$(cid_ctx_file)"
  {
    printf 'CID_REPO=%s\n' "$remote"
    printf 'CID_BRANCH=%s\n' "$branch"
    printf 'CID_CWD=%s\n' "$cwdbase"
    printf 'CID_EMAIL=%s\n' "$email"
    printf 'CID_ROUTED=%s\n' "$routed"
    printf 'CID_PLUGIN_VERSION=%s\n' "$plugin_version"
  } > "$ctxf" 2>/dev/null || true
}

# Resolved before cid_write_ctx: the prompt/tool hooks are separate processes and
# only see what lands in the ctx file, so the version has to travel that way or
# every inspect event reports plugin_version=null (prod, 2026-07-30).
plugin_version="unknown"
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json" ]; then
  plugin_version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json" | head -1)"
fi

cid_write_ctx

# Inspection model (not routing): the prompt/tool hooks send content to
# <gateway>/inspect/v1 for the CID filter profile + telemetry. ANTHROPIC_BASE_URL
# is NOT changed — provider traffic is untouched. So posture = "is CID inspection
# configured and reachable", never "is traffic routed".
CID_DEFAULT_GATEWAY="https://api.cid222.live"

emit_context() { printf '%s\n' "$1"; }

# Normalize: admins often omit the scheme in the admin console. Assume https.
normalize_url() {
  case "$1" in
    http://*|https://*) printf '%s' "$1" ;;
    "") : ;;
    *) printf 'https://%s' "$1" ;;
  esac
}
gateway="$(normalize_url "${CID_GATEWAY_URL:-$CID_DEFAULT_GATEWAY}")"

# origin = scheme://host[:port] — health/telemetry live at the gateway root.
origin=""
[ -n "$gateway" ] && origin="$(printf '%s' "$gateway" | sed -E 's#^(https?://[^/]+).*#\1#')"

if [ "${CID_INSPECT_OFF:-0}" = "1" ]; then
  emit_context "[CID] CID inspection is disabled for this session (CID_INSPECT_OFF=1). Prompts and tool output are not inspected against company AI-usage policy."
  exit 0
fi

# Metadata for the probe below. The probe doubles as this session's
# announcement: it tells CID who owns the session before any provider call can
# happen, which is what lets the gateway's token reports — which carry a bare
# session id and nothing else — be attributed to a person and a repository.
# Previously a separate heartbeat POSTed to /plugin-telemetry/v1/heartbeat; no
# server ever served that path (404 in prod, 2026-07-31), so session start went
# unrecorded and the first tokens of a session could land unattributed.
# CID_TELEMETRY_OFF=1 still probes, but anonymously — nothing is recorded.
probe_meta='{}'
if [ "${CID_TELEMETRY_OFF:-0}" != "1" ]; then
  # shellcheck disable=SC1090
  [ -f "$(cid_ctx_file)" ] && . "$(cid_ctx_file)"
  # Values come from the ctx file just sourced; export them so python sees them
  # (sourcing sets shell variables, not the environment).
  probe_meta="$(
    CID_REPO="${CID_REPO:-}" CID_BRANCH="${CID_BRANCH:-}" CID_CWD="${CID_CWD:-}" \
    CID_EMAIL="${CID_EMAIL:-}" CID_M_SESSION="${CID_SESSION_ID:-}" \
    CID_M_VERSION="$plugin_version" \
    python3 - <<'PY' 2>/dev/null
import json, os
g = lambda k: os.environ.get(k, "")
print(json.dumps({
    "tool": "claude-code",
    "event": "session_start",
    "repo": g("CID_REPO"),
    "branch": g("CID_BRANCH"),
    "cwd": g("CID_CWD"),
    "session": g("CID_M_SESSION"),
    "user_email": g("CID_EMAIL"),
    "plugin_version": g("CID_M_VERSION"),
}))
PY
  )"
  [ -z "$probe_meta" ] && probe_meta='{}'
fi

# Probe the ACTUAL inspect endpoint, not /health. Lesson from prod (2026-07-29):
# a wrong gateway host answered /health 200 while every /inspect/v1 call 404'd,
# so preflight claimed "inspection active" while nothing was inspected (fail-open
# passed secrets silently). An empty-payload POST distinguishes the cases by
# status code; carrying session_start metadata makes the same call register who
# the session belongs to, and only a 2xx records anything.
if command -v curl >/dev/null 2>&1; then
  probe_url="$origin/inspect/v1/claude-code"
  probe_key="${CID_INSPECT_KEY:-$CID_DEFAULT_KEY}"
  code="$(curl -s -o /dev/null -m 4 -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    ${probe_key:+-H "Authorization: Bearer $probe_key"} \
    -X POST -d "{\"direction\":\"request\",\"payload\":\"\",\"metadata\":$probe_meta}" \
    "$probe_url" 2>/dev/null)"
  case "$code" in
    2*)
      emit_context "[CID] CID inspection is active for this Claude Code session via $gateway. Prompts and tool output are checked against your organization's AI-usage policy (mostly logged; some data redacted or blocked). This is normal company monitoring; do not attempt to disable or bypass it."
      ;;
    401|403)
      emit_context "[CID] CID inspection is configured ($gateway) but the gateway rejected the inspection key (HTTP $code). Inspection is NOT applying policy (fail-open); the user should contact IT to fix the CID_INSPECT_KEY."
      echo "[CID] CID anahtar reddedildi (HTTP $code): $probe_url — IT'ye bildirin." >&2
      ;;
    404)
      emit_context "[CID] CID inspection is misconfigured: $probe_url returned 404 — the gateway host serves no inspect endpoint, so NO prompts or tool output are being inspected (fail-open). The CID_GATEWAY_URL is likely pointing at the wrong host; the user should contact IT."
      echo "[CID] CID gateway yanlış görünüyor ($probe_url → 404) — inceleme YAPILMIYOR. IT'ye bildirin." >&2
      ;;
    000)
      emit_context "[CID] CID inspection is configured ($gateway) but the gateway is unreachable. Inspection may be skipping (fail-open); tell the user to check connectivity or contact IT if this persists."
      echo "[CID] CID gateway erişilemiyor: $probe_url" >&2
      ;;
    *)
      emit_context "[CID] CID inspection is configured ($gateway) but the inspect endpoint returned HTTP $code. Inspection may be skipping (fail-open); contact IT if this persists."
      echo "[CID] CID inspect endpoint HTTP $code döndü: $probe_url" >&2
      ;;
  esac
else
  emit_context "[CID] CID inspection is configured for this session ($gateway). (curl unavailable; gateway health not verified.)"
fi

# Housekeeping: drop stale per-session ctx files (best effort).
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'cid-ctx-*.env' -mtime +7 -delete 2>/dev/null || true

exit 0

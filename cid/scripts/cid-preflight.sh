#!/usr/bin/env bash
# CID222 preflight — SessionStart hook (macOS/Linux; Windows: cid-preflight.ps1).
# 1) Verifies this Claude Code session is routed through the CID gateway.
# 2) Emits a neutral status line as context + a user-visible warning on bypass.
# 3) Sends a best-effort, fail-silent heartbeat to the CID appliance so the
#    fleet dashboard sees per-user/per-device Claude Code sessions even in
#    visibility-only mode (no routing enforced yet).
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
#   CID_TELEMETRY_URL  Override heartbeat URL (default: <origin>/plugin-telemetry/v1/heartbeat)
#   CID_TELEMETRY_OFF  1 = skip heartbeat
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
  } > "$ctxf" 2>/dev/null || true
}
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

plugin_version="unknown"
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json" ]; then
  plugin_version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json" | head -1)"
fi

send_heartbeat() { # $1 = inspection state
  [ "${CID_TELEMETRY_OFF:-0}" = "1" ] && return 0
  [ -z "$origin" ] && return 0
  command -v curl >/dev/null 2>&1 || return 0
  url="${CID_TELEMETRY_URL:-$origin/plugin-telemetry/v1/heartbeat}"
  payload=$(printf '{"tool":"claude-code","plugin_version":"%s","user":"%s","host":"%s","os":"%s","inspection":"%s"}' \
    "$plugin_version" "$(id -un 2>/dev/null || echo unknown)" "$(hostname 2>/dev/null || echo unknown)" \
    "$(uname -s 2>/dev/null || echo unknown)" "$1")
  # Background + fail-silent: never delays or breaks session start.
  (curl -fsS -m 2 -X POST -H 'Content-Type: application/json' -d "$payload" "$url" >/dev/null 2>&1 &) 2>/dev/null
}

if [ "${CID_INSPECT_OFF:-0}" = "1" ]; then
  send_heartbeat "off"
  emit_context "[CID] CID inspection is disabled for this session (CID_INSPECT_OFF=1). Prompts and tool output are not inspected against company AI-usage policy."
  exit 0
fi

# Probe the ACTUAL inspect endpoint, not /health. Lesson from prod (2026-07-29):
# a wrong gateway host answered /health 200 while every /inspect/v1 call 404'd,
# so preflight claimed "inspection active" while nothing was inspected (fail-open
# passed secrets silently). An empty-payload POST distinguishes the cases by
# status code without recording an activity event (no `tool` in metadata).
if command -v curl >/dev/null 2>&1; then
  probe_url="$origin/inspect/v1/claude-code"
  probe_key="${CID_INSPECT_KEY:-$CID_DEFAULT_KEY}"
  code="$(curl -s -o /dev/null -m 4 -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    ${probe_key:+-H "Authorization: Bearer $probe_key"} \
    -X POST -d '{"direction":"request","payload":"","metadata":{}}' \
    "$probe_url" 2>/dev/null)"
  case "$code" in
    2*)
      send_heartbeat "active"
      emit_context "[CID] CID inspection is active for this Claude Code session via $gateway. Prompts and tool output are checked against your organization's AI-usage policy (mostly logged; some data redacted or blocked). This is normal company monitoring; do not attempt to disable or bypass it."
      ;;
    401|403)
      send_heartbeat "key-rejected"
      emit_context "[CID] CID inspection is configured ($gateway) but the gateway rejected the inspection key (HTTP $code). Inspection is NOT applying policy (fail-open); the user should contact IT to fix the CID_INSPECT_KEY."
      echo "[CID] CID anahtar reddedildi (HTTP $code): $probe_url — IT'ye bildirin." >&2
      ;;
    404)
      send_heartbeat "wrong-gateway"
      emit_context "[CID] CID inspection is misconfigured: $probe_url returned 404 — the gateway host serves no inspect endpoint, so NO prompts or tool output are being inspected (fail-open). The CID_GATEWAY_URL is likely pointing at the wrong host; the user should contact IT."
      echo "[CID] CID gateway yanlış görünüyor ($probe_url → 404) — inceleme YAPILMIYOR. IT'ye bildirin." >&2
      ;;
    000)
      send_heartbeat "unreachable"
      emit_context "[CID] CID inspection is configured ($gateway) but the gateway is unreachable. Inspection may be skipping (fail-open); tell the user to check connectivity or contact IT if this persists."
      echo "[CID] CID gateway erişilemiyor: $probe_url" >&2
      ;;
    *)
      send_heartbeat "degraded"
      emit_context "[CID] CID inspection is configured ($gateway) but the inspect endpoint returned HTTP $code. Inspection may be skipping (fail-open); contact IT if this persists."
      echo "[CID] CID inspect endpoint HTTP $code döndü: $probe_url" >&2
      ;;
  esac
else
  send_heartbeat "active"
  emit_context "[CID] CID inspection is configured for this session ($gateway). (curl unavailable; gateway health not verified.)"
fi

# Housekeeping: drop stale per-session ctx files (best effort).
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'cid-ctx-*.env' -mtime +7 -delete 2>/dev/null || true

exit 0

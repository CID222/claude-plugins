#!/usr/bin/env bash
# Shared helpers for the CID Claude Code hooks (macOS/Linux). Sourced by the
# hook scripts; not run directly. Windows equivalents live in cid-common.ps1.
#
# Env contract (from managed settings "env"):
#   CID_GATEWAY_URL     gateway base URL (scheme optional). Origin used for
#                       /inspect/v1 and /health.
#   CID_INSPECT_KEY     cid_key_ used as the Bearer for /inspect/v1 (identifies
#                       the company tenant/group -> selects its filter profile).
#   CID_FAIL_OPEN       1 (default) = on CID error/timeout, allow the action.
#                       0 = fail closed (block prompts / keep raw output).
#   CID_INSPECT_OFF     1 = skip all inspection (telemetry + filtering off).
#   CID_INSPECT_TIMEOUT seconds for the inspect call (default 4).
#
# BAKED DEFAULTS: this build ships pointed at the CID222 hosted gateway with a
# key scoped to the "Claude Code" tenant group (log-first profile). The zip
# works out of the box with no configuration. Managed settings override any of
# these via the env vars above. The baked key is an INSPECTION key (log/flag
# policy), not a provider credential; rotate it in the dashboard if leaked.
CID_DEFAULT_GATEWAY="https://api.cid222.live"
CID_DEFAULT_KEY="cid_key_c530392f852248f65b1b6550e5dfdb33202541ac2fc7b270ec02f67d59ced458"

# Normalize a bare host to https://.
cid_norm_url() {
  case "$1" in
    http://*|https://*) printf '%s' "$1" ;;
    "") : ;;
    *) printf 'https://%s' "$1" ;;
  esac
}

cid_origin() {
  printf '%s' "$1" | sed -E 's#^(https?://[^/]+).*#\1#'
}

# --- Session identity ---------------------------------------------------------
# Claude Code does NOT export CLAUDE_SESSION_ID to hook processes; each hook
# receives its own session_id in the JSON payload on stdin. Trusting the env var
# collapsed every session onto one context file (concurrent sessions in
# different repos overwrote each other's repo/branch) and sent an empty
# `session` in telemetry, so byRepo session counts were always 0.
# Callers set CID_SESSION_ID from their hook payload before calling cid_inspect.

# Keep only characters that are safe in a filename — the value becomes one.
cid_sanitize_id() {
  printf '%s' "$1" | tr -cd 'A-Za-z0-9._-' | cut -c1-64
}

# $1 = raw hook JSON (may be empty). Prints the resolved session id, or "".
cid_session_from_hook() {
  sid=""
  if [ -n "${1:-}" ]; then
    sid="$(printf '%s' "$1" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("session_id","") or "")
except Exception: pass' 2>/dev/null)"
  fi
  [ -z "$sid" ] && sid="${CID_SESSION_ID:-}"
  [ -z "$sid" ] && sid="${CLAUDE_SESSION_ID:-}"
  cid_sanitize_id "$sid"
}

# Filename-safe session key; "nosession" only when the id is genuinely unknown.
cid_session_key() {
  k="$(cid_sanitize_id "${CID_SESSION_ID:-}")"
  [ -z "$k" ] && k="nosession"
  printf '%s' "$k"
}

# Per-session cache of the git/repo context (computed once in SessionStart).
cid_ctx_file() {
  printf '%s/cid-ctx-%s.env' "${TMPDIR:-/tmp}" "$(cid_session_key)"
}

# JSON-string-escape stdin (backslash, quote, control chars).
cid_json_escape() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))' 2>/dev/null \
    || sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a;N;$!ba;s/\n/\\n/g'
}

# Read the Claude seat email from ~/.claude.json (best-effort; internal file).
cid_seat_email() {
  python3 - <<'PY' 2>/dev/null || true
import json, os, pathlib
p = pathlib.Path.home() / ".claude.json"
try:
    d = json.loads(p.read_text())
    print((d.get("oauthAccount") or {}).get("emailAddress") or "")
except Exception:
    pass
PY
}

# Call POST /inspect/v1/claude-code.
#   $1 = direction (request|response)
#   $2 = payload (raw text)
#   $3 = event   (prompt|tool_use)
# Optional, exported by the caller: CID_TOOL_NAME and CID_TOOL_PATH describe
# which tool ran and what it touched. Paths only — never file contents, and for
# Bash only the leading command word, because arguments carry secrets.
# Prints the JSON verdict body on stdout; empty on error. Sends repo/branch/
# session/user_email/cwd as metadata (telemetry rides this same call).
cid_inspect() {
  [ "${CID_INSPECT_OFF:-0}" = "1" ] && return 0
  command -v curl >/dev/null 2>&1 || return 0
  local base origin key direction payload event ctxf
  base="$(cid_norm_url "${CID_GATEWAY_URL:-$CID_DEFAULT_GATEWAY}")"
  [ -z "$base" ] && return 0
  origin="$(cid_origin "$base")"
  key="${CID_INSPECT_KEY:-$CID_DEFAULT_KEY}"
  direction="$1"; payload="$2"; event="$3"
  ctxf="$(cid_ctx_file)"
  local repo="" branch="" cwdbase="" email=""
  # shellcheck disable=SC1090
  [ -f "$ctxf" ] && . "$ctxf"
  repo="${CID_REPO:-}"; branch="${CID_BRANCH:-}"; cwdbase="${CID_CWD:-}"; email="${CID_EMAIL:-}"

  local pj mj session
  pj="$(printf '%s' "$payload" | cid_json_escape)"
  session="$(cid_sanitize_id "${CID_SESSION_ID:-}")"
  mj=$(cat <<JSON
{"tool":"claude-code","event":"$event","repo":"$repo","branch":"$branch","cwd":"$cwdbase","session":"$session","user_email":"$email","plugin_version":"${CID_PLUGIN_VERSION:-}","tool_name":"${CID_TOOL_NAME:-}","tool_path":"${CID_TOOL_PATH:-}"}
JSON
)
  local body
  body=$(printf '{"direction":"%s","payload":%s,"metadata":%s}' "$direction" "$pj" "$mj")
  curl -fsS -m "${CID_INSPECT_TIMEOUT:-4}" \
    -H 'Content-Type: application/json' \
    ${key:+-H "Authorization: Bearer $key"} \
    -X POST -d "$body" \
    "$origin/inspect/v1/claude-code" 2>/dev/null
}

# Call POST /assess/v1/claude-code — the code-safety action gate. Unlike
# cid_inspect (content inspection), this carries a composed JSON body from the
# caller ($1) and returns the decision body {decision, reason, matched_rule}.
# Same bearer key: the gateway resolves the tenant group from it and short-
# circuits to "allow" when the group has code safety disabled.
# Prints the JSON verdict on stdout; empty on error/timeout (caller decides
# fail-open vs fail-closed).
cid_assess() {
  [ "${CID_INSPECT_OFF:-0}" = "1" ] && return 0
  command -v curl >/dev/null 2>&1 || return 0
  local base origin key url
  base="$(cid_norm_url "${CID_GATEWAY_URL:-$CID_DEFAULT_GATEWAY}")"
  [ -z "$base" ] && return 0
  origin="$(cid_origin "$base")"
  key="${CID_INSPECT_KEY:-$CID_DEFAULT_KEY}"
  url="${CID_ASSESS_URL:-$origin/assess/v1/claude-code}"
  curl -fsS -m "${CID_ASSESS_TIMEOUT:-4}" \
    -H 'Content-Type: application/json' \
    ${key:+-H "Authorization: Bearer $key"} \
    -X POST -d "$1" "$url" 2>/dev/null
}

# Extract a top-level string field ($2) from a JSON verdict ($1).
cid_json_field() {
  printf '%s' "$1" | python3 -c "import json,sys;
try: print(json.load(sys.stdin).get('$2',''))
except Exception: pass" 2>/dev/null
}

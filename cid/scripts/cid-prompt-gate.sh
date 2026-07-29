#!/usr/bin/env bash
# UserPromptSubmit hook. Sends the typed prompt to CID /inspect/v1 (which also
# records the telemetry event), and blocks the prompt when the company filter
# profile returns a blocking verdict. Log-only rules return ALLOW and just get
# recorded — the common case.
#
# stdin: JSON with field `prompt`. stdout: {"decision":"block","reason":…} to
# block, or nothing to allow.
set -u

here="$(dirname "$0")"
# shellcheck disable=SC1091
. "$here/cid-common.sh"

# Read the hook payload once; session_id lives in this JSON (Claude Code does
# not export CLAUDE_SESSION_ID to hooks), the prompt is field `prompt`.
hook_json="$(cat 2>/dev/null)"
CID_SESSION_ID="$(cid_session_from_hook "$hook_json")"
export CID_SESSION_ID

prompt="$(printf '%s' "$hook_json" | python3 -c 'import json,sys;
try: print(json.load(sys.stdin).get("prompt",""), end="")
except Exception: pass' 2>/dev/null)"
[ -z "$prompt" ] && exit 0

verdict_json="$(cid_inspect request "$prompt" prompt)"

# Fail-open (default): CID unreachable/timeout -> allow. Fail-closed blocks.
if [ -z "$verdict_json" ]; then
  if [ "${CID_FAIL_OPEN:-1}" = "0" ]; then
    printf '%s\n' '{"decision":"block","reason":"CID policy service unreachable and this device is set to fail-closed. Try again once the CID gateway is reachable, or contact IT."}'
  fi
  exit 0
fi

verdict="$(cid_json_field "$verdict_json" verdict)"
case "$verdict" in
  BLOCK|REDACT)
    # A prompt cannot be silently masked; a REDACT rule on the prompt path is
    # enforced as a block. Surface the CID reasons.
    reasons="$(cid_json_field "$verdict_json" reasons)"
    msg="CID policy blocked this prompt (it contains data your organization's Claude Code policy does not allow). Remove the sensitive content and resend."
    [ -n "$reasons" ] && msg="$msg Detected: $reasons"
    printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "$msg" | cid_json_escape)"
    ;;
  *)
    : # ALLOW (incl. flag/log-only) — recorded, prompt proceeds.
    ;;
esac
exit 0

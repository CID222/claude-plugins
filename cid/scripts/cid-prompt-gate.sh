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
reasons="$(cid_json_field "$verdict_json" reasons)"

# Verdict → action. CID's MASK rules come back as REDACT; its REJECT rules come
# back as BLOCK.
#
# Claude Code's hook protocol cannot rewrite a prompt (only PreToolUse/
# PostToolUse can rewrite; UserPromptSubmit is block-or-allow), so a MASK rule
# is unmaskable here. Blocking it — what v0.5.1 did — turned every MASK rule
# into a REJECT, so a prompt merely mentioning an email never reached the model.
# That contradicts the log-first profile these rules are written for.
#
# Default: MASK → let the prompt through and record it, with a factual note in
# context and a warning to the user. Sites that would rather refuse the prompt
# than let the value reach the provider set CID_PROMPT_MASK_ACTION=block.
case "$verdict" in
  BLOCK)
    msg="CID policy blocked this prompt (it contains data your organization's Claude Code policy does not allow). Remove the sensitive content and resend."
    [ -n "$reasons" ] && msg="$msg Detected: $reasons"
    printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "$msg" | cid_json_escape)"
    ;;
  REDACT)
    if [ "${CID_PROMPT_MASK_ACTION:-warn}" = "block" ]; then
      msg="CID policy blocked this prompt: it contains values your organization masks, and prompt text cannot be masked in place. Remove or redact the sensitive content and resend."
      [ -n "$reasons" ] && msg="$msg Detected: $reasons"
      printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "$msg" | cid_json_escape)"
    else
      # Factual status only — imperative text arriving from a hook reads as a
      # prompt-injection attempt and gets refused (observed 2026-07-28).
      note="CID222 policy note: this prompt contains values your organization classifies as sensitive"
      [ -n "$reasons" ] && note="$note ($reasons)"
      note="$note. The rule is mask-level, and Claude Code's hook protocol cannot mask prompt text, so the prompt was recorded and passed through unchanged rather than blocked. Tool output on the same session is still masked."
      printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' \
        "$(printf '%s' "$note" | cid_json_escape)"
      echo "[CID] Bu istemde maskelenmesi gereken veri var${reasons:+ ($reasons)}; maskeleme prompt metnine uygulanamıyor, istem kayda alınıp iletildi." >&2
    fi
    ;;
  *)
    : # ALLOW (incl. flag/log-only) — recorded, prompt proceeds.
    ;;
esac
exit 0

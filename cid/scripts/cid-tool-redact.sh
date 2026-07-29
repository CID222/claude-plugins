#!/usr/bin/env bash
# PostToolUse hook (Read|Grep|Bash) — thin wrapper. The logic lives in
# cid-tool-redact.py so the hook's stdin (the tool JSON) flows straight into
# python (a `python3 <<HEREDOC` would consume stdin itself). Fail-open: any
# error leaves the tool output untouched.
exec python3 "$(dirname "$0")/cid-tool-redact.py"

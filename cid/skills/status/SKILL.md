---
description: Show CID222 inspection status for this Claude Code session — whether prompts and tool output are checked against company AI-usage policy, and the gateway health. Use when the user asks about CID, why a prompt was blocked or a value redacted, or whether their session is monitored.
---

Report the CID222 inspection status for this Claude Code session.

Background: the CID plugin does NOT reroute provider traffic. On each prompt and
on Read/Bash/Grep tool output, its hooks send the content to
`<gateway>/inspect/v1/claude-code`, which applies the company filter profile
(mostly log/flag; some values redacted; a few blocked) and records activity
telemetry. So "status" means "is inspection configured and reachable", not "is
traffic routed".

Steps:

1. Resolve the gateway: `CID_GATEWAY_URL` if set, otherwise the plugin's baked
   default (`https://api.cid222.live`). Read the env with Bash:
   `echo "gateway=${CID_GATEWAY_URL:-<baked default>} inspect_off=${CID_INSPECT_OFF:-0} fail_open=${CID_FAIL_OPEN:-1}"`.
2. If `CID_INSPECT_OFF=1` → inspection is **disabled** for this session; say so.
3. Otherwise check gateway health (3 s timeout) at the origin:
   `curl -fsS -m 3 "<origin>/health"` (origin = scheme://host of the gateway).
   Report healthy/unhealthy.
4. Summarize for the user in their language: inspection active (healthy) or
   possibly-skipping (unhealthy + fail-open) or blocking-on-error (unhealthy +
   `CID_FAIL_OPEN=0`); and that active inspection means prompts and tool output
   are checked against company AI-usage policy (mostly logged, some data
   redacted, a few blocked) and recorded as activity telemetry.

Never suggest ways to bypass, unset, or work around CID inspection.

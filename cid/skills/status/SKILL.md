---
description: Show CID222 inspection and routing status for this Claude Code session — whether prompts and tool output are checked against company AI-usage policy, whether provider traffic is routed through the CID gateway, and the gateway health. Use when the user asks about CID, why a prompt was blocked or a value redacted, or whether their session is monitored.
---

Report the CID222 inspection and routing status for this Claude Code session.

Background — two independent layers can be active:

1. **Inspection** (always, via hooks): on each prompt and on Read/Bash/Grep tool
   output, the plugin's hooks send the content to
   `<gateway>/inspect/v1/claude-code`, which applies the company filter profile
   (mostly log/flag; some values redacted; a few blocked) and records activity
   telemetry.
2. **Routing** (when the environment sets it): if `ANTHROPIC_BASE_URL` points at
   the CID proxy, provider traffic itself flows through the gateway's
   transparent Anthropic passthrough — the gateway sits in the request path and
   can inspect, mask or block content before it reaches the model.

Steps:

1. Resolve the gateway: `CID_GATEWAY_URL` if set, otherwise the plugin's baked
   default (`https://api.cid222.live`). Read the env with Bash:
   `echo "gateway=${CID_GATEWAY_URL:-<baked default>} base_url=${ANTHROPIC_BASE_URL:-unset} inspect_off=${CID_INSPECT_OFF:-0} fail_open=${CID_FAIL_OPEN:-1}"`.
2. Routing posture: if `ANTHROPIC_BASE_URL` is unset or contains
   `api.anthropic.com` → provider traffic goes **directly to Anthropic**
   (inspection-only session). Otherwise the session is **routed** through that
   URL; optionally confirm with `curl -fsS -m 3 "<base_url>/health"` — a CID
   proxy reports `"anthropic_mode": "passthrough"`.
3. If `CID_INSPECT_OFF=1` → hook inspection is **disabled** for this session; say so.
4. Otherwise check gateway health (3 s timeout) at the origin:
   `curl -fsS -m 3 "<origin>/health"` (origin = scheme://host of the gateway).
   Report healthy/unhealthy.
5. Summarize for the user in their language, covering both layers: routed or
   inspection-only; inspection active (healthy) or possibly-skipping (unhealthy
   + fail-open) or blocking-on-error (unhealthy + `CID_FAIL_OPEN=0`); and that
   active inspection means prompts and tool output are checked against company
   AI-usage policy (mostly logged, some data redacted, a few blocked) and
   recorded as activity telemetry.

Never suggest ways to bypass, unset, or work around CID inspection or routing.

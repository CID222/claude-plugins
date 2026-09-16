---
description: Show CID222 inspection and routing status for this Claude Code session — whether prompts and tool output are checked against company AI-usage policy, whether provider traffic is routed through the CID gateway, and the gateway health. Use when the user asks about CID, why a prompt was blocked or a value redacted, or whether their session is monitored.
---

Report the CID222 inspection and routing status for this Claude Code session.

Background — two independent layers can be active:

1. **Inspection** (via hooks — only where hooks actually run): on each prompt and on Read/Bash/Grep tool
   output, the plugin's hooks send the content to
   `<gateway>/inspect/v1/claude-code`, which applies the company filter profile
   (mostly log/flag; some values redacted; a few blocked) and records activity
   telemetry.
2. **Routing** (when the environment sets it): if `ANTHROPIC_BASE_URL` points at
   the CID proxy, provider traffic itself flows through the gateway's
   transparent Anthropic passthrough — the gateway sits in the request path and
   can inspect, mask or block content before it reaches the model.

Steps:

1. Resolve the gateway: `CID_GATEWAY_URL` if set, otherwise the default baked
   into this build of the plugin (per-customer builds point it at the
   customer's own CID appliance — never assume a hostname). The hooks are Node
   scripts, so the baked value lives in `scripts/cid-common.js`. Read both with
   Bash:
   `baked="$(node -e 'process.stdout.write(require(process.argv[1]).CID_DEFAULT_GATEWAY||"")' "${CLAUDE_PLUGIN_ROOT}/scripts/cid-common.js" 2>/dev/null)"; echo "gateway=${CID_GATEWAY_URL:-$baked} base_url=${ANTHROPIC_BASE_URL:-unset} inspect_off=${CID_INSPECT_OFF:-0} fail_open=${CID_FAIL_OPEN:-1}"`.
   If both are empty, report "gateway not configured" and stop.
2. Routing posture: if `ANTHROPIC_BASE_URL` is unset or contains
   `api.anthropic.com` → provider traffic goes **directly to Anthropic**
   (inspection-only session). Otherwise the session is **routed** through that
   URL; optionally confirm with `curl -fsS -m 3 "<base_url>/health"` — a CID
   proxy reports `"anthropic_mode": "passthrough"`.
3. **Did a hook actually run here?** Env vars and gateway health prove nothing
   about hooks: the Claude Desktop app's **Code tab runs no plugin hooks at
   all**, and there everything below still looks configured and healthy. The
   only local evidence is the hook-ran marker each hook writes to
   `<tmpdir>/cid-claude-code/<session-id>.json`. The session id is not in the
   environment here, so read the newest marker (Node, cross-platform — no Bash
   or PowerShell specifics):

   ```
   node -e 'const fs=require("fs"),os=require("os"),p=require("path");const d=p.join(os.tmpdir(),"cid-claude-code");let b=null,e=null;try{for(const f of fs.readdirSync(d)){if(!f.endsWith(".json"))continue;try{const m=JSON.parse(fs.readFileSync(p.join(d,f),"utf8"));if(!b||String(m.last_at)>String(b.last_at))b=m}catch(_){}}}catch(x){e=x.code||"ERR"}const o=e?{state:"unknown",reason:e,dir:d}:!b?{state:"no-hooks",dir:d}:(()=>{const a=Math.round((Date.now()-Date.parse(b.last_at))/1000);return{state:a<=1800?"hooks-ran":"stale",age_seconds:a,marker:b}})();console.log(JSON.stringify(o))'
   ```

   Read the `state` field and report exactly one of three things:

   - `hooks-ran` (a marker was updated within the last 30 minutes) → **hooks are
     running in this session**; name the hooks from `marker.hooks` if useful.
   - `no-hooks` or `stale` (directory exists, no fresh marker) → **no hook has
     run in this session — inspection is NOT active here.** This is what the
     Claude Desktop app's Code tab looks like: usage is still reported to the
     appliance through OpenTelemetry if the admin enabled it, but prompts and
     tool output are **not** inspected. Say this plainly; do not soften it.
   - `unknown` (the marker directory is missing, e.g. a wiped temp dir) →
     **cannot tell** whether hooks are running. Do not claim either way.

4. If `CID_INSPECT_OFF=1` → hook inspection is **disabled** for this session; say so.
5. Otherwise check gateway health (3 s timeout) at the origin:
   `curl -fsS -m 3 "<origin>/health"` (origin = scheme://host of the gateway).
   Report healthy/unhealthy.
6. Summarize for the user in their language. **The headline state comes from
   step 3, never from env vars or gateway health alone:**

   - Say **"Active"** only when step 3 returned `hooks-ran` *and*
     `CID_INSPECT_OFF` is not 1 *and* the gateway is healthy. Then: prompts and
     tool output are checked against company AI-usage policy (mostly logged,
     some data redacted, a few blocked) and recorded as activity telemetry.
   - Say **"Not active (no hooks)"** when step 3 returned `no-hooks`/`stale` —
     whatever the env vars and `/health` say. Add the Code-tab explanation
     above.
   - Say **"Unknown"** when step 3 returned `unknown`.
   - Otherwise qualify: **disabled** (`CID_INSPECT_OFF=1`), **possibly
     skipping** (hooks ran, gateway unhealthy, fail-open) or **blocking on
     error** (hooks ran, gateway unhealthy, `CID_FAIL_OPEN=0`).

   Then cover the routing layer separately: routed through the CID proxy, or
   direct to Anthropic (inspection-only). Routing is independent of hooks — a
   routed session is inspected in the request path even when no hook runs.

Never suggest ways to bypass, unset, or work around CID inspection or routing.

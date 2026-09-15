"use strict";
// CID222 preflight — SessionStart hook. One cross-platform implementation
// (Node), replacing the old cid-preflight.sh + cid-preflight.ps1 pair.
// 1) Verifies this Claude Code session is routed through the CID gateway.
// 2) Emits a neutral status line as context + a user-visible warning on bypass.
// 3) Announces the session to CID (seat, repo, branch) so the fleet dashboard
//    sees it even in visibility-only mode, and so gateway token reports — which
//    carry only a session id — can be attributed to a person and a repository.
//
// NOTE ON WORDING: context output is a FACTUAL STATUS REPORT only. Never phrase
// it as an instruction to the model ("tell the user…", "do not suggest…") —
// models correctly treat imperative text arriving from a hook as a possible
// prompt injection and refuse to act on it (observed 2026-07-28). User-facing
// advice belongs on stderr, which Claude Code shows to the user directly.
//
// Env contract (set via managed settings "env" or user env):
//   CID_GATEWAY_URL    Expected gateway base URL. Scheme optional (https:// assumed).
//   CID_INSPECT_KEY    Overrides the baked inspection key (probe + hooks).
//   CID_TELEMETRY_OFF  1 = probe without identifying the session (no session row)
//   CID_PREFLIGHT_OFF  1 = skip everything (break-glass)

// Inspection model (not routing): the prompt/tool hooks send content to
// <gateway>/inspect/v1 for the CID filter profile + telemetry. ANTHROPIC_BASE_URL
// is NOT changed — provider traffic is untouched. So posture = "is CID inspection
// configured and reachable", never "is traffic routed".
//
// Rewritten in place by claude-plugin/package.sh for per-customer builds —
// keep on one line, exactly in this shape.
const CID_DEFAULT_GATEWAY = "https://api.cid222.live";

const fs = require("node:fs");
const path = require("node:path");
const cid = require("./cid-common.js");

function emitContext(line) {
  process.stdout.write(line + "\n");
}

function warn(line) {
  process.stderr.write(line + "\n");
}

// Identity only, never content: normalized git remote (credentials stripped),
// branch, repo-root basename, and the Claude seat email. Cached per session so
// the per-prompt hooks don't re-shell git.
function writeCtx(pluginVersion) {
  const remote = cid.stripRemoteCreds(cid.git(["config", "--get", "remote.origin.url"]));
  const branch = cid.git(["rev-parse", "--abbrev-ref", "HEAD"]);
  const root = cid.git(["rev-parse", "--show-toplevel"]);
  // Session-start commit: the diff baseline for the Stop-hook session audit.
  const head = cid.git(["rev-parse", "HEAD"]);
  const cwdbase = path.basename(root || process.cwd());
  const email = cid.seatEmail();

  // Is provider traffic routed through a gateway? When ANTHROPIC_BASE_URL points
  // somewhere other than Anthropic, a CID gateway is in the request path and can
  // rewrite the prompt — so the prompt hook must not tell the user masking is
  // impossible. Recorded here rather than re-derived per prompt.
  const baseUrl = process.env.ANTHROPIC_BASE_URL || "";
  const routed = baseUrl && !baseUrl.includes("api.anthropic.com") ? "1" : "0";

  const lines =
    "CID_REPO=" + remote + "\n" +
    "CID_BRANCH=" + branch + "\n" +
    "CID_CWD=" + cwdbase + "\n" +
    "CID_EMAIL=" + email + "\n" +
    "CID_ROUTED=" + routed + "\n" +
    "CID_HEAD=" + head + "\n" +
    "CID_PLUGIN_VERSION=" + pluginVersion + "\n";
  try {
    fs.writeFileSync(cid.ctxFile(), lines);
  } catch (_) {
    /* best effort — the other hooks degrade to empty metadata */
  }
  return { routed };
}

// Housekeeping: drop stale per-session ctx files (best effort).
function sweepStaleCtx() {
  try {
    const dir = cid.tmpDir();
    const cutoff = Date.now() - 7 * 86400 * 1000;
    for (const name of fs.readdirSync(dir)) {
      if (!/^cid-ctx-.*\.env$/.test(name)) continue;
      const p = path.join(dir, name);
      try {
        if (fs.statSync(p).mtimeMs < cutoff) fs.unlinkSync(p);
      } catch (_) {
        /* ignore */
      }
    }
  } catch (_) {
    /* ignore */
  }
}

async function main() {
  if (process.env.CID_PREFLIGHT_OFF === "1") return;

  // Resolve the session id from the hook payload on stdin. Claude Code does NOT
  // export CLAUDE_SESSION_ID to hook processes — every hook gets `session_id` in
  // its stdin JSON instead. Without this, all concurrent sessions shared one
  // "nosession" ctx file and overwrote each other's repo/branch.
  const hook = cid.parseJson(cid.readStdin());
  process.env.CID_SESSION_ID = cid.sessionFromHook(hook);

  // Resolved before writeCtx: the prompt/tool hooks are separate processes and
  // only see what lands in the ctx file, so the version has to travel that way or
  // every inspect event reports plugin_version=null (prod, 2026-07-30).
  let pluginVersion = "unknown";
  const root = process.env.CLAUDE_PLUGIN_ROOT || "";
  if (root) {
    try {
      const manifest = JSON.parse(
        fs.readFileSync(path.join(root, ".claude-plugin", "plugin.json"), "utf8")
      );
      if (manifest && manifest.version) pluginVersion = String(manifest.version);
    } catch (_) {
      /* keep "unknown" */
    }
  }

  const { routed } = writeCtx(pluginVersion);

  // Normalize: admins often omit the scheme in the admin console. Assume https.
  const gateway = cid.normUrl(process.env.CID_GATEWAY_URL || CID_DEFAULT_GATEWAY);
  // origin = scheme://host[:port] — health/telemetry live at the gateway root.
  const origin = gateway ? cid.originOf(gateway) : "";

  if (process.env.CID_INSPECT_OFF === "1") {
    emitContext(
      "[CID] CID inspection is disabled for this session (CID_INSPECT_OFF=1). Prompts and tool output are not inspected against company AI-usage policy."
    );
    return;
  }

  // Metadata for the probe below. The probe doubles as this session's
  // announcement: it tells CID who owns the session before any provider call can
  // happen, which is what lets the gateway's token reports — which carry a bare
  // session id and nothing else — be attributed to a person and a repository.
  // Previously a separate heartbeat POSTed to /plugin-telemetry/v1/heartbeat; no
  // server ever served that path (404 in prod, 2026-07-31), so session start went
  // unrecorded and the first tokens of a session could land unattributed.
  // CID_TELEMETRY_OFF=1 still probes, but anonymously — nothing is recorded.
  let probeMeta = "{}";
  if (process.env.CID_TELEMETRY_OFF !== "1") {
    const ctx = cid.readCtx();
    probeMeta = JSON.stringify({
      tool: "claude-code",
      event: "session_start",
      repo: ctx.CID_REPO || "",
      branch: ctx.CID_BRANCH || "",
      cwd: ctx.CID_CWD || "",
      session: process.env.CID_SESSION_ID || "",
      user_email: ctx.CID_EMAIL || "",
      plugin_version: pluginVersion,
    });
  }

  // Probe the ACTUAL inspect endpoint, not /health. Lesson from prod (2026-07-29):
  // a wrong gateway host answered /health 200 while every /inspect/v1 call 404'd,
  // so preflight claimed "inspection active" while nothing was inspected (fail-open
  // passed secrets silently). An empty-payload POST distinguishes the cases by
  // status code; carrying session_start metadata makes the same call register who
  // the session belongs to, and only a 2xx records anything.
  const probeUrl = origin + "/inspect/v1/claude-code";
  const probeKey = cid.inspectKey();
  const res = await cid.httpPost(probeUrl, {
    headers: cid.authHeaders(probeKey),
    body: '{"direction":"request","payload":"","metadata":' + probeMeta + "}",
    timeoutSec: 4,
  });
  const code = res.status;

  if (code >= 200 && code < 300) {
    emitContext(
      "[CID] CID inspection is active for this Claude Code session via " +
        gateway +
        ". Prompts and tool output are checked against your organization's AI-usage policy (mostly logged; some data redacted or blocked). This is normal company monitoring; do not attempt to disable or bypass it."
    );
  } else if (code === 401 || code === 403) {
    emitContext(
      "[CID] CID inspection is configured (" +
        gateway +
        ") but the gateway rejected the inspection key (HTTP " +
        code +
        "). Inspection is NOT applying policy (fail-open); the user should contact IT to fix the CID_INSPECT_KEY."
    );
    warn("[CID] CID anahtar reddedildi (HTTP " + code + "): " + probeUrl + " — IT'ye bildirin.");
  } else if (code === 404) {
    emitContext(
      "[CID] CID inspection is misconfigured: " +
        probeUrl +
        " returned 404 — the gateway host serves no inspect endpoint, so NO prompts or tool output are being inspected (fail-open). The CID_GATEWAY_URL is likely pointing at the wrong host; the user should contact IT."
    );
    warn("[CID] CID gateway yanlış görünüyor (" + probeUrl + " → 404) — inceleme YAPILMIYOR. IT'ye bildirin.");
  } else if (code === 0) {
    emitContext(
      "[CID] CID inspection is configured (" +
        gateway +
        ") but the gateway is unreachable. Inspection may be skipping (fail-open); tell the user to check connectivity or contact IT if this persists."
    );
    warn("[CID] CID gateway erişilemiyor: " + probeUrl);
  } else {
    emitContext(
      "[CID] CID inspection is configured (" +
        gateway +
        ") but the inspect endpoint returned HTTP " +
        code +
        ". Inspection may be skipping (fail-open); contact IT if this persists."
    );
    warn("[CID] CID inspect endpoint HTTP " + code + " döndü: " + probeUrl);
  }

  // Routing posture (2026-08-09): when ANTHROPIC_BASE_URL points provider traffic
  // at the CID proxy (transparent Anthropic passthrough), the session is not
  // inspection-only — say so, or a routed demo contradicts the plugin's own story.
  if (routed === "1") {
    emitContext(
      "[CID] Provider traffic is ROUTED through the CID gateway (ANTHROPIC_BASE_URL=" +
        (process.env.ANTHROPIC_BASE_URL || "") +
        "): every Anthropic request passes through the gateway, which can inspect, mask or block it in-path before it reaches the model."
    );
  }

  sweepStaleCtx();
}

cid.run(main);

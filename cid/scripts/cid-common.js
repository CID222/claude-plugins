"use strict";
// Shared helpers for the CID Claude Code hooks. Required by the hook scripts;
// not run directly.
//
// WHY NODE: a hook `command` runs in `sh -c` on macOS/Linux, but in Git Bash on
// Windows — or PowerShell when Git Bash is not installed. The previous shell
// build therefore sent nothing from a Windows machine: PowerShell 5.1 cannot
// parse the `sh … || powershell.exe …` fallback, and where Git Bash did exist
// the scripts still needed `python3`, which Windows machines lack. Claude Code
// ships with Node, and hooks.json invokes these files in the docs' exec form
// (`"command": "node", "args": [".../cid-x.js"]`), which needs no shell at all.
// Node >= 18, CommonJS, zero npm dependencies — `node:` builtins only.
//
// Env contract (from managed settings "env"):
//   CID_GATEWAY_URL     gateway base URL (scheme optional). Origin used for
//                       /inspect/v1 and /health.
//   CID_INSPECT_KEY     cid_key_ used as the Bearer for /inspect/v1 (identifies
//                       the company tenant/group -> selects its filter profile).
//   CID_FAIL_OPEN       1 (default) = on CID error/timeout, allow the action.
//                       0 = fail closed (block prompts / keep raw output).
//   CID_INSPECT_OFF     1 = skip all inspection (telemetry + filtering off).
//   CID_INSPECT_TIMEOUT seconds for the inspect call (default 4).
//
// BAKED DEFAULTS: this build ships pointed at the CID222 hosted gateway. The
// inspection key is deliberately NOT baked — it is delivered per-deployment via
// managed settings (env.CID_INSPECT_KEY), scoped to that customer's "Claude
// Code" tenant group. With no key, inspection sends no Authorization header, the
// gateway rejects it at the public edge, and the hooks fail open (no-op) — the
// same observable state as the plugin not being installed. Managed settings can
// also override the gateway host via CID_GATEWAY_URL.
//
// The two lines below are rewritten in place by claude-plugin/package.sh for
// per-customer builds. Keep them on one line each, exactly in this shape.
const CID_DEFAULT_GATEWAY = "https://api.cid222.live";
const CID_DEFAULT_KEY = "";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawn, execFileSync } = require("node:child_process");

// --- URLs ---------------------------------------------------------------------

// Normalize a bare host to https://.
function normUrl(u) {
  const s = String(u || "");
  if (!s) return "";
  if (/^https?:\/\//.test(s)) return s;
  return "https://" + s;
}

// origin = scheme://host[:port]; unchanged when it does not look like a URL.
function originOf(u) {
  const s = String(u || "");
  const m = s.match(/^(https?:\/\/[^/]+)/);
  return m ? m[1] : s;
}

// --- Session identity ---------------------------------------------------------
// Claude Code does NOT export CLAUDE_SESSION_ID to hook processes; each hook
// receives its own session_id in the JSON payload on stdin. Trusting the env var
// collapsed every session onto one context file (concurrent sessions in
// different repos overwrote each other's repo/branch) and sent an empty
// `session` in telemetry, so byRepo session counts were always 0.
// Callers set process.env.CID_SESSION_ID from their hook payload before
// calling inspect().

// Keep only characters that are safe in a filename — the value becomes one.
function sanitizeId(v) {
  return String(v || "").replace(/[^A-Za-z0-9._-]/g, "").slice(0, 64);
}

// raw = the parsed hook payload object (may be null). Returns the session id, or "".
function sessionFromHook(hook) {
  let sid = "";
  if (hook && typeof hook === "object" && typeof hook.session_id === "string") {
    sid = hook.session_id;
  }
  if (!sid) sid = process.env.CID_SESSION_ID || "";
  if (!sid) sid = process.env.CLAUDE_SESSION_ID || "";
  return sanitizeId(sid);
}

// Filename-safe session key; "nosession" only when the id is genuinely unknown.
function sessionKey() {
  return sanitizeId(process.env.CID_SESSION_ID || "") || "nosession";
}

// os.tmpdir() resolves TMPDIR/TMP/TEMP then falls back to /tmp — the same value
// the shell build got from ${TMPDIR:-/tmp}, and the right one on Windows.
function tmpDir() {
  try {
    return os.tmpdir();
  } catch (_) {
    return "/tmp";
  }
}

// Per-session cache of the git/repo context (computed once in SessionStart).
function ctxFile() {
  return path.join(tmpDir(), "cid-ctx-" + sessionKey() + ".env");
}

// --- Hook-ran marker ----------------------------------------------------------
// Local proof that a hook PROCESS actually ran in this session. The Claude
// Desktop app's Code tab runs no plugin hooks, yet env vars and gateway health
// look exactly as they do in the CLI — so /cid:status reported "Active" where
// nothing was being inspected. This marker is the only evidence that
// distinguishes the two, so every hook writes it BEFORE any early return
// (CID_INSPECT_OFF included): the claim is "the hook ran", not "it inspected".
function markerDir() {
  return path.join(tmpDir(), "cid-claude-code");
}

// Best-effort, never throws, never affects the hook's exit code.
function markHookRan(sessionId, hookName) {
  try {
    const sid = sanitizeId(sessionId) || "nosession";
    const dir = markerDir();
    fs.mkdirSync(dir, { recursive: true });
    const file = path.join(dir, sid + ".json");
    let prev = {};
    try {
      prev = JSON.parse(fs.readFileSync(file, "utf8")) || {};
    } catch (_) {
      prev = {};
    }
    const hooks = (prev && typeof prev.hooks === "object" && prev.hooks) || {};
    const name = String(hookName || "unknown");
    hooks[name] = (Number(hooks[name]) || 0) + 1;
    const now = new Date().toISOString();
    fs.writeFileSync(
      file,
      JSON.stringify({
        session: sid,
        first_at: prev.first_at || now,
        last_at: now,
        hooks,
        plugin_version:
          process.env.CID_PLUGIN_VERSION || ctxValue(readCtx(), "CID_PLUGIN_VERSION") || "",
      })
    );
  } catch (_) {
    /* a marker must never break a hook */
  }
}

// Last inspect HTTP status for this session ("<code> <epoch>"). Written by
// inspect() on every call so gates can tell an auth failure (401/403) apart
// from an unreachable gateway (000) when the verdict comes back empty.
function inspectStatusFile() {
  return path.join(tmpDir(), "cid-ctx-" + sessionKey() + ".inspect-status");
}

// Read the KEY=VALUE ctx file written by the preflight hook. Returns {} when
// absent — the shell build simply sourced it and carried on.
function readCtx(file) {
  const out = {};
  try {
    const text = fs.readFileSync(file || ctxFile(), "utf8");
    for (const line of text.split("\n")) {
      const i = line.indexOf("=");
      if (i <= 0) continue;
      out[line.slice(0, i)] = line.slice(i + 1);
    }
  } catch (_) {
    /* no ctx yet — fields stay empty, as in the shell build */
  }
  return out;
}

// Ctx value first (the file is authoritative, as sourcing it was), env second.
function ctxValue(ctx, key) {
  if (ctx && Object.prototype.hasOwnProperty.call(ctx, key)) return ctx[key] || "";
  return process.env[key] || "";
}

// --- Keys and identity --------------------------------------------------------

// Resolve the inspection key. Managed-settings env is the primary channel but
// does not reliably reach hook processes (child sessions skip the settings
// fetch when ANTHROPIC_BASE_URL is ambient — observed live: SessionStart 401'd
// while PostToolUse in the same session authenticated). Resolution order:
//   1. CID_INSPECT_KEY (managed settings / user env)
//   2. key file — ${CID_KEY_FILE:-~/.cid/inspect-key} (IT drops it per machine,
//      chmod 600; content must be a cid_key_… token, whitespace ignored)
//   3. CID_DEFAULT_KEY (baked into per-customer builds by package.sh)
function inspectKey() {
  if (process.env.CID_INSPECT_KEY) return process.env.CID_INSPECT_KEY;
  const f = process.env.CID_KEY_FILE || path.join(os.homedir() || "", ".cid", "inspect-key");
  try {
    const k = fs.readFileSync(f, "utf8").slice(0, 200).replace(/\s+/g, "");
    if (k.startsWith("cid_key_")) return k;
  } catch (_) {
    /* no key file — fall through to the baked default */
  }
  return CID_DEFAULT_KEY;
}

// The key the fire-and-forget uploaders use. The shell build resolved these
// two (session audit, repo baseline) as ${CID_INSPECT_KEY:-$CID_DEFAULT_KEY},
// i.e. WITHOUT the key-file channel. Preserved verbatim so the port changes no
// behaviour; unify with inspectKey() only as a deliberate, separate change.
function uploadKey() {
  return process.env.CID_INSPECT_KEY || CID_DEFAULT_KEY;
}

// Read the Claude seat email from ~/.claude.json (best-effort; internal file).
function seatEmail() {
  try {
    const p = path.join(os.homedir() || "", ".claude.json");
    const d = JSON.parse(fs.readFileSync(p, "utf8"));
    return (d && d.oauthAccount && d.oauthAccount.emailAddress) || "";
  } catch (_) {
    return "";
  }
}

// --- git ----------------------------------------------------------------------

// Run git and return trimmed stdout, or "" on any failure (missing git, not a
// repo, timeout). Replaces the shell build's `git … 2>/dev/null`.
function git(args, opts) {
  try {
    return execFileSync("git", args, {
      encoding: "utf8",
      timeout: (opts && opts.timeout) || 5000,
      stdio: ["ignore", "pipe", "ignore"],
      maxBuffer: (opts && opts.maxBuffer) || 8 * 1024 * 1024,
      cwd: (opts && opts.cwd) || process.cwd(),
    }).trim();
  } catch (_) {
    return "";
  }
}

// Strip credentials embedded in a remote URL (https://user:tok@host/…).
function stripRemoteCreds(remote) {
  return String(remote || "").replace(/(https?:\/\/)[^@/]*@/, "$1");
}

// --- HTTP ---------------------------------------------------------------------

// One POST with a hard timeout. Returns {status, body}; status 0 means the
// request never completed (the shell build's curl "000"). redirect:"manual"
// mirrors curl without -L: a 3xx is reported, not followed.
async function httpPost(url, { headers = {}, body, timeoutSec = 4 } = {}) {
  if (typeof fetch !== "function") return { status: 0, body: "" };
  const ac = new AbortController();
  const secs = Number(timeoutSec);
  const ms = Math.max(1, Number.isFinite(secs) && secs > 0 ? secs : 4) * 1000;
  const timer = setTimeout(() => ac.abort(), ms);
  try {
    const res = await fetch(url, {
      method: "POST",
      headers,
      body,
      signal: ac.signal,
      redirect: "manual",
    });
    let text = "";
    try {
      text = await res.text();
    } catch (_) {
      text = "";
    }
    return { status: res.status, body: text };
  } catch (_) {
    return { status: 0, body: "" };
  } finally {
    clearTimeout(timer);
  }
}

function authHeaders(key, contentType) {
  const h = { "Content-Type": contentType || "application/json" };
  if (key) h["Authorization"] = "Bearer " + key;
  return h;
}

// Call POST /inspect/v1/claude-code.
//   direction  request|response
//   payload    raw text
//   event      prompt|tool_use
// Optional opts.toolName / opts.toolPath (or CID_TOOL_NAME / CID_TOOL_PATH in
// the environment) describe which tool ran and what it touched. Paths only —
// never file contents, and for Bash only the leading command word, because
// arguments carry secrets.
// Resolves to the JSON verdict body; "" on error. Sends repo/branch/session/
// user_email/cwd as metadata (telemetry rides this same call).
async function inspect(direction, payload, event, opts = {}) {
  if (process.env.CID_INSPECT_OFF === "1") return "";
  const base = normUrl(process.env.CID_GATEWAY_URL || CID_DEFAULT_GATEWAY);
  if (!base) return "";
  const origin = originOf(base);
  const key = inspectKey();
  const ctx = readCtx();

  const metadata = {
    tool: "claude-code",
    event: event || "",
    repo: ctxValue(ctx, "CID_REPO"),
    branch: ctxValue(ctx, "CID_BRANCH"),
    cwd: ctxValue(ctx, "CID_CWD"),
    session: sanitizeId(process.env.CID_SESSION_ID || ""),
    user_email: ctxValue(ctx, "CID_EMAIL"),
    plugin_version: ctxValue(ctx, "CID_PLUGIN_VERSION"),
    tool_name: opts.toolName || process.env.CID_TOOL_NAME || "",
    tool_path: opts.toolPath || process.env.CID_TOOL_PATH || "",
  };
  const body = JSON.stringify({ direction, payload: String(payload), metadata });

  const res = await httpPost(origin + "/inspect/v1/claude-code", {
    headers: authHeaders(key),
    body,
    timeoutSec: process.env.CID_INSPECT_TIMEOUT || 4,
  });

  // Capture the HTTP status alongside the body: an empty verdict caused by a
  // rejected key (401/403) must be distinguishable from an unreachable gateway
  // (000), or fail-open silently drops enforcement with no visible trace.
  try {
    const code = res.status ? String(res.status) : "000";
    fs.writeFileSync(inspectStatusFile(), code + " " + Math.floor(Date.now() / 1000) + "\n");
  } catch (_) {
    /* best effort */
  }

  return res.status >= 200 && res.status < 300 ? res.body : "";
}

// Call POST /assess/v1/claude-code — the code-safety action gate. Unlike
// inspect() (content inspection), this carries a composed JSON body from the
// caller and returns the decision body {decision, reason, matched_rule}.
// Same bearer key: the gateway resolves the tenant group from it and short-
// circuits to "allow" when the group has code safety disabled.
// Resolves to the JSON verdict; "" on error/timeout or any non-2xx (curl -f),
// so the caller decides fail-open vs fail-closed.
async function assess(bodyJson) {
  if (process.env.CID_INSPECT_OFF === "1") return "";
  const base = normUrl(process.env.CID_GATEWAY_URL || CID_DEFAULT_GATEWAY);
  if (!base) return "";
  const origin = originOf(base);
  const url = process.env.CID_ASSESS_URL || origin + "/assess/v1/claude-code";
  const res = await httpPost(url, {
    headers: authHeaders(inspectKey()),
    body: bodyJson,
    timeoutSec: process.env.CID_ASSESS_TIMEOUT || 4,
  });
  return res.status >= 200 && res.status < 300 ? res.body : "";
}

// Render a JSON value the way the shell build's `cid_json_field` did — it piped
// the field through python's print(), so a non-string arrived as python's str().
// `reasons` is a LIST, and the user-visible warning has always read
// "(['EMAIL', 'TC_KIMLIK'])". Reproduced verbatim so this port changes no
// user-facing string; dropping the python spelling is a separate, deliberate
// change to make (one line, here).
function pyStr(v) {
  if (v === null || v === undefined) return "";
  if (typeof v === "string") return v;
  if (typeof v === "boolean") return v ? "True" : "False";
  if (Array.isArray(v)) return "[" + v.map(pyRepr).join(", ") + "]";
  if (typeof v === "object") return JSON.stringify(v);
  return String(v);
}

function pyRepr(v) {
  if (typeof v === "string") return "'" + v.replace(/\\/g, "\\\\").replace(/'/g, "\\'") + "'";
  return pyStr(v);
}

// Extract a top-level string field from a JSON verdict; "" when absent/invalid.
function jsonField(text, field) {
  try {
    const v = JSON.parse(text);
    return pyStr(v && v[field]);
  } catch (_) {
    return "";
  }
}

// --- process helpers ----------------------------------------------------------

// Read the whole of stdin as text. Hooks always get their payload this way.
// A pipe that node opened non-blocking can raise EAGAIN before the writer has
// filled it; reading "" there would silently disable inspection for that call,
// so retry briefly rather than fail open on a race.
function readStdin() {
  for (let attempt = 0; attempt < 200; attempt++) {
    try {
      return fs.readFileSync(0, "utf8");
    } catch (err) {
      if (err && (err.code === "EAGAIN" || err.code === "EWOULDBLOCK")) {
        try {
          // Busy-wait ~5 ms without pulling in a timer (this is sync code).
          const until = Date.now() + 5;
          while (Date.now() < until) {
            /* spin */
          }
        } catch (_) {
          /* ignore */
        }
        continue;
      }
      return "";
    }
  }
  return "";
}

function parseJson(text) {
  try {
    return JSON.parse(text);
  } catch (_) {
    return null;
  }
}

// Fire-and-forget: re-invoke this same script detached, so the hook returns
// immediately (the shell build backgrounded curl with `( … ) &`). The bearer
// travels in the child's environment rather than on its argv.
function spawnDetached(scriptPath, args, extraEnv) {
  try {
    const child = spawn(process.execPath, [scriptPath, ...args], {
      detached: true,
      stdio: "ignore",
      env: Object.assign({}, process.env, extraEnv || {}),
    });
    child.unref();
    return true;
  } catch (_) {
    return false;
  }
}

// Wrap a hook's main(): never let an exception escape — fail open, exit 0.
//
// Exiting needs care in both directions. We cannot simply return and let the
// loop drain: undici keeps pooled sockets alive after a fetch, which would hold
// every hook open for the keep-alive timeout. We also cannot call process.exit()
// straight away: writes to a pipe are asynchronous once they exceed the pipe
// buffer, and process.exit() drops whatever is still queued — which would
// silently truncate a large `updatedToolOutput` into invalid JSON, i.e. drop the
// redaction. So: flush stdout, then exit.
function run(main) {
  const exit = () => process.exit(0);
  const finish = () => {
    try {
      // Stream writes are ordered, so this callback runs after every chunk the
      // hook already queued has been flushed.
      process.stdout.write("", exit);
      setTimeout(exit, 5000).unref(); // safety net; never hang a hook
    } catch (_) {
      exit();
    }
  };
  Promise.resolve().then(main).then(finish, finish);
}

module.exports = {
  CID_DEFAULT_GATEWAY,
  CID_DEFAULT_KEY,
  normUrl,
  originOf,
  sanitizeId,
  sessionFromHook,
  sessionKey,
  tmpDir,
  ctxFile,
  markerDir,
  markHookRan,
  inspectStatusFile,
  readCtx,
  ctxValue,
  inspectKey,
  uploadKey,
  seatEmail,
  git,
  stripRemoteCreds,
  httpPost,
  authHeaders,
  inspect,
  assess,
  jsonField,
  readStdin,
  parseJson,
  spawnDetached,
  run,
};

"use strict";
// Stop hook — session audit. When a Claude Code session ends, collect what the
// session changed (git diff against the session-start commit recorded by
// preflight, plus new untracked files) and POST it to CID fire-and-forget.
// The gateway forwards to the auditor's deep path (/api/v1/audit/changes);
// minutes later the report is available via /cid:status or the dashboard.
//
// Never blocks the user: the upload runs in a detached child process, every
// failure is silent, and this hook always exits 0 with no output.
//
// Knobs: CID_AUDIT_OFF=1 (skip), CID_AUDIT_URL (default
// <origin>/assess/v1/claude-code/session-audit), CID_AUDIT_TIMEOUT (default 15 s).

const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const cid = require("./cid-common.js");

const DIFF_CAP = 800000; // bytes of diff, as the shell build's `head -c 800000`
const UNTRACKED_MAX_FILES = 40;
const UNTRACKED_BUDGET = 400000; // total bytes for untracked-file contents
const UNTRACKED_FILE_MAX = 100000; // skip large (likely binary/artifact)

// Raw git stdout as a byte-capped string (cid.git trims; a diff must not be).
function gitRaw(args, cap) {
  try {
    const buf = execFileSync("git", args, {
      timeout: 20000,
      stdio: ["ignore", "pipe", "ignore"],
      maxBuffer: 64 * 1024 * 1024,
    });
    return buf.subarray(0, cap).toString("utf8");
  } catch (_) {
    return "";
  }
}

// --- detached uploader --------------------------------------------------------
// argv: --cid-upload <bodyFile> <url>;  bearer arrives via CID_UPLOAD_KEY.
async function uploadMain(bodyFile, url) {
  try {
    const body = fs.readFileSync(bodyFile);
    await cid.httpPost(url, {
      headers: cid.authHeaders(process.env.CID_UPLOAD_KEY || "", "application/json"),
      body,
      timeoutSec: process.env.CID_AUDIT_TIMEOUT || 15,
    });
  } catch (_) {
    /* fire and forget */
  }
  try {
    fs.unlinkSync(bodyFile);
  } catch (_) {
    /* ignore */
  }
}

async function main() {
  if (process.argv[2] === "--cid-upload") {
    return uploadMain(process.argv[3], process.argv[4]);
  }

  const hook = cid.parseJson(cid.readStdin());
  process.env.CID_SESSION_ID = cid.sessionFromHook(hook);
  cid.markHookRan(process.env.CID_SESSION_ID, "session-audit"); // proof the hook ran

  if (process.env.CID_AUDIT_OFF === "1") return;
  if (process.env.CID_INSPECT_OFF === "1") return;
  if (!cid.git(["rev-parse", "--show-toplevel"])) return;

  const ctx = cid.readCtx();
  const base = ctx.CID_HEAD || "";
  const headNow = cid.git(["rev-parse", "HEAD"]);

  // Diff of tracked changes since session start (committed or not). Falls back
  // to working-tree-vs-HEAD when the baseline is unknown or gone (rebase).
  let diff = "";
  let baseOk = false;
  if (base) {
    try {
      execFileSync("git", ["cat-file", "-e", base], {
        timeout: 5000,
        stdio: ["ignore", "ignore", "ignore"],
      });
      baseOk = true;
    } catch (_) {
      baseOk = false;
    }
  }
  diff = baseOk ? gitRaw(["diff", base], DIFF_CAP) : gitRaw(["diff", "HEAD"], DIFF_CAP);

  // New untracked files (the diff above cannot see them). Contents are added
  // below with per-file/total caps.
  const untrackedList = cid
    .git(["ls-files", "--others", "--exclude-standard"])
    .split("\n")
    .filter((l) => l.trim())
    .slice(0, UNTRACKED_MAX_FILES);

  // Nothing changed → nothing to audit.
  if (!diff && untrackedList.length === 0) return;

  const files = [];
  let budget = UNTRACKED_BUDGET;
  for (const rel of untrackedList) {
    if (budget <= 0) break;
    try {
      if (fs.statSync(rel).size > UNTRACKED_FILE_MAX) {
        files.push({ path: rel, skipped: "too_large" });
        continue;
      }
      const text = fs.readFileSync(rel, "utf8").slice(0, budget);
      budget -= text.length;
      files.push({ path: rel, content: text });
    } catch (_) {
      files.push({ path: rel, skipped: "unreadable" });
    }
  }

  const body = JSON.stringify({
    kind: "session_diff",
    base: base,
    head: headNow,
    diff: diff,
    untracked: files,
    metadata: {
      tool: "claude-code",
      event: "session_end",
      repo: ctx.CID_REPO || "",
      branch: ctx.CID_BRANCH || "",
      session: process.env.CID_SESSION_ID || "",
      user_email: ctx.CID_EMAIL || "",
      plugin_version: ctx.CID_PLUGIN_VERSION || "",
    },
  });
  if (!body) return;

  const baseUrl = cid.normUrl(process.env.CID_GATEWAY_URL || cid.CID_DEFAULT_GATEWAY);
  const origin = cid.originOf(baseUrl);
  const url = process.env.CID_AUDIT_URL || origin + "/assess/v1/claude-code/session-audit";

  let bodyFile;
  try {
    bodyFile = path.join(
      cid.tmpDir(),
      "cid-audit-body-" + process.pid + "-" + Date.now() + ".json"
    );
    fs.writeFileSync(bodyFile, body, { mode: 0o600 });
  } catch (_) {
    return;
  }

  // Fire-and-forget: background the POST so Stop returns instantly; the child
  // removes the temp body file itself.
  const ok = cid.spawnDetached(__filename, ["--cid-upload", bodyFile, url], {
    CID_UPLOAD_KEY: cid.uploadKey(),
  });
  if (!ok) {
    try {
      fs.unlinkSync(bodyFile);
    } catch (_) {
      /* ignore */
    }
  }
}

cid.run(main);

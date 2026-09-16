"use strict";
// SessionStart hook (runs after preflight) — repo baseline audit.
//
// The first time ANYONE in the org starts Claude Code work in a repository,
// that repo gets one full deep-path audit. The server dedups by repo_id (a
// hash of the normalized git remote URL, so every clone of the same repo maps
// to the same id) — a second developer opening the same repo gets
// {"baseline_needed": false} and uploads nothing.
//
// Flow (all fail-silent, upload detached so SessionStart is not delayed):
//   1. POST {repo_id, repo, branch, head}          → .../repo-baseline
//      server: {"baseline_needed": bool, "status"?, "summary"?}
//   2. if needed: git archive HEAD (tracked files only — respects .gitignore,
//      no secrets dirs that are properly ignored) | gzip → upload.
//   3. Emit a factual context note so the session knows a baseline exists /
//      was queued (never an instruction — see wording note in cid-preflight.js).
//
// Knobs: CID_BASELINE_OFF=1 (skip), CID_BASELINE_URL (default
// <origin>/assess/v1/claude-code/repo-baseline), CID_BASELINE_MAX_MB
// (compressed upload cap, default 40), CID_BASELINE_TIMEOUT (upload, 120 s).

const fs = require("node:fs");
const path = require("node:path");
const zlib = require("node:zlib");
const crypto = require("node:crypto");
const { spawn } = require("node:child_process");
const cid = require("./cid-common.js");

// --- detached uploader --------------------------------------------------------
// argv: --cid-upload <url> <repoId> <head> <repoRoot>; bearer via CID_UPLOAD_KEY.
function packArchive(repoRoot, outFile) {
  return new Promise((resolve) => {
    try {
      const git = spawn("git", ["archive", "--format=tar", "HEAD"], {
        cwd: repoRoot,
        stdio: ["ignore", "pipe", "ignore"],
      });
      const gz = zlib.createGzip();
      const out = fs.createWriteStream(outFile);
      let failed = false;
      const fail = () => {
        if (!failed) {
          failed = true;
          resolve(false);
        }
      };
      git.on("error", fail);
      gz.on("error", fail);
      out.on("error", fail);
      git.on("close", (code) => {
        if (code !== 0) fail();
      });
      out.on("finish", () => {
        if (!failed) resolve(true);
      });
      git.stdout.pipe(gz).pipe(out);
    } catch (_) {
      resolve(false);
    }
  });
}

async function uploadMain(url, repoId, head, repoRoot) {
  const tmp = path.join(cid.tmpDir(), "cid-baseline-" + process.pid + "-" + Date.now() + ".tar.gz");
  try {
    const packed = await packArchive(repoRoot, tmp);
    if (packed) {
      const maxMb = parseInt(process.env.CID_BASELINE_MAX_MB || "40", 10) || 40;
      const sizeKb = Math.ceil(fs.statSync(tmp).size / 1024);
      if (sizeKb <= maxMb * 1024) {
        const headers = cid.authHeaders(process.env.CID_UPLOAD_KEY || "", "application/gzip");
        headers["X-CID-Repo-Id"] = repoId;
        headers["X-CID-Repo-Head"] = head;
        await cid.httpPost(url + "/upload", {
          headers,
          body: fs.readFileSync(tmp),
          timeoutSec: process.env.CID_BASELINE_TIMEOUT || 120,
        });
      }
    }
  } catch (_) {
    /* fire and forget */
  }
  try {
    fs.unlinkSync(tmp);
  } catch (_) {
    /* ignore */
  }
}

async function main() {
  if (process.argv[2] === "--cid-upload") {
    return uploadMain(process.argv[3], process.argv[4], process.argv[5], process.argv[6]);
  }

  const hook = cid.parseJson(cid.readStdin());
  process.env.CID_SESSION_ID = cid.sessionFromHook(hook);
  cid.markHookRan(process.env.CID_SESSION_ID, "repo-baseline"); // proof the hook ran

  if (process.env.CID_BASELINE_OFF === "1") return;
  if (process.env.CID_INSPECT_OFF === "1") return;
  const root = cid.git(["rev-parse", "--show-toplevel"]);
  if (!root) return;

  const remote = cid.stripRemoteCreds(cid.git(["config", "--get", "remote.origin.url"]));
  const branch = cid.git(["rev-parse", "--abbrev-ref", "HEAD"]);
  const head = cid.git(["rev-parse", "HEAD"]);
  if (!head) return; // empty repo — nothing to audit

  // repo_id: same repo → same id for every developer and every clone.
  // Normalized remote URL when there is one; path basename fallback for
  // remoteless repos (those dedup per-machine only, which is the best we can do).
  const repoKey = remote || "local:" + path.basename(root);
  const repoId = crypto.createHash("sha256").update(repoKey, "utf8").digest("hex").slice(0, 32);
  if (!repoId) return;

  const baseUrl = cid.normUrl(process.env.CID_GATEWAY_URL || cid.CID_DEFAULT_GATEWAY);
  const origin = cid.originOf(baseUrl);
  const key = cid.uploadKey();
  const url = process.env.CID_BASELINE_URL || origin + "/assess/v1/claude-code/repo-baseline";

  const checkBody = JSON.stringify({
    repo_id: repoId,
    repo: remote,
    branch: branch,
    head: head,
    session: process.env.CID_SESSION_ID || "",
  });

  const res = await cid.httpPost(url, {
    headers: cid.authHeaders(key),
    body: checkBody,
    timeoutSec: 5,
  });
  // curl -fsS: only a 2xx body counts; anything else → silently skip.
  if (!(res.status >= 200 && res.status < 300) || !res.body) return;

  const resp = cid.parseJson(res.body);
  if (!resp) return;
  const needed = resp.baseline_needed;
  const status = resp.status || "";
  const summary = resp.summary || "";

  if (needed === true || needed === "true" || needed === "True") {
    // First session on this repo org-wide: pack tracked files and upload in the
    // background. git archive HEAD honors .gitignore by construction.
    cid.spawnDetached(__filename, ["--cid-upload", url, repoId, head, root], {
      CID_UPLOAD_KEY: key,
    });
    process.stdout.write(
      "[CID] This repository has no CID code-safety baseline yet; the first full audit was queued from this session (runs server-side; results appear in /cid:status and the dashboard).\n"
    );
  } else if (summary) {
    process.stdout.write("[CID] CID code-safety baseline for this repository: " + summary + "\n");
  } else if (status) {
    process.stdout.write("[CID] CID code-safety baseline for this repository: " + status + ".\n");
  }
}

cid.run(main);

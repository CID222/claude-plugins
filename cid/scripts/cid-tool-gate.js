"use strict";
// PreToolUse hook (Bash|PowerShell|Write|Edit|MultiEdit|NotebookEdit) — the
// code-safety tool gate. Sends the action (a shell command, or file content
// about to be written) to CID's assess route, which resolves the tenant group,
// applies its policy and consults the cid-code-safety auditor. One round trip
// per gated tool call; the auditor's fast path is deterministic-only (~34 ms
// measured), so the user feels roughly network latency.
//
// Decision contract (server → hook → Claude Code):
//   allow      exit 0, silent — the tool runs.
//   advise     tool runs; a FACTUAL note enters context so the agent can
//              self-correct. (CID ladder extension; core may map findings here.)
//   ask        Claude Code's native permission prompt with the reason.
//   interrupt  permissionDecision "deny" with reason + rule id. Only
//              deterministic high-confidence findings may produce this.
//
// Fail-open by default (CID unreachable → tool runs, nothing recorded).
// CID_FAIL_OPEN=0 turns unreachable into a deny — strict groups only.
//
// NOTE ON WORDING: any text that reaches the model (advise notes, deny
// reasons) must be a factual status report, never an instruction — imperative
// hook text reads as prompt injection and gets refused (observed 2026-07-28).
//
// A LOCAL deterministic gate runs first (no network). It covers, for commands:
// destructive SQL (DROP/TRUNCATE/WHERE-less DELETE|UPDATE/GRANT ALL), destructive
// filesystem (rm -rf, dd, mkfs, shred, wipefs, chmod -R 777, fork bomb), git
// history rewrite (force push, reset --hard, clean -f), remote-code/supply-chain
// (curl|sh, eval/interp of downloads, iex, pip-from-url, insecure npm registry),
// disabled TLS/host-key verification, infra destruction (kubectl/terraform/helm/
// docker prune), persistence & system tampering (shell rc, crontab, /etc, sudoers,
// firewall/SELINUX off), and secret exfiltration — all → native "ask". For file
// writes: hardcoded secrets (AWS/GitHub/Slack/Anthropic/Google/OpenAI keys,
// private keys) → ask; insecure-code patterns + CI/Docker footguns → advise. This
// makes the gate meaningful even where the /assess route isn't deployed yet; when
// it is, the server verdict layers on top for everything the local rules miss.
//
// The Windows PowerShell tool carries its command in the same `tool_input.command`
// field as Bash, and on a Windows box without Git Bash the Bash tool is not even
// registered — so both tool names take the command path.
//
// Knobs: CID_TOOLGATE_OFF=1 (skip gate entirely), CID_LOCAL_GATE_OFF=1 (skip
// only the local deterministic rules, keep the server assess call),
// CID_ASSESS_URL, CID_ASSESS_TIMEOUT (default 4 s), CID_FAIL_OPEN (default 1),
// plus the shared cid-common.js env.

const cid = require("./cid-common.js");

const COMMAND_TOOLS = ["Bash", "PowerShell"];
const FILE_TOOLS = ["Write", "Edit", "MultiEdit", "NotebookEdit"];
const CAP = 200000; // bytes of content per assess call; auditor rules are line-local

// Extract the text this tool is about to act on, plus the file path if any.
function toolText(tool, ti) {
  if (COMMAND_TOOLS.includes(tool)) {
    return { path: "", text: ti.command || "" };
  }
  if (FILE_TOOLS.includes(tool)) {
    const fpath = ti.file_path || ti.notebook_path || "";
    if (tool === "Write") return { path: fpath, text: ti.content || "" };
    if (tool === "Edit") return { path: fpath, text: ti.new_string || "" };
    if (tool === "MultiEdit") {
      const edits = Array.isArray(ti.edits) ? ti.edits : [];
      return { path: fpath, text: edits.map((e) => (e && e.new_string) || "").join("\n") };
    }
    return { path: fpath, text: ti.new_source || "" };
  }
  return null;
}

// ---- Local deterministic high-risk gate (runs with NO backend) --------------
// Matches a short list of unambiguously destructive patterns in the command (or
// the file content about to be written) and, on a hit, emits a native "ask" so
// Claude Code shows its confirmation prompt with the reason. Deterministic and
// offline: the demo-safe floor beneath the server assess verdict.
function localGate(hook) {
  const tool = String((hook && hook.tool_name) || "");
  const ti = (hook && hook.tool_input) || {};
  const picked = toolText(tool, ti);
  if (!picked) return null;

  const raw = picked.text || "";
  const flat = raw.replace(/\s+/g, " ").trim();
  const low = flat.toLowerCase();
  const flow = String(picked.path || "").toLowerCase();
  if (!flat) return null;

  const ask = [];
  const advise = [];
  const A = (rid, why) => ask.push([rid, why]);
  const V = (rid, why) => advise.push([rid, why]);

  if (COMMAND_TOOLS.includes(tool)) {
    // --- SQL ---
    if (/\bdrop\s+(table|database|schema)\b/.test(low)) A("cc-sql-drop", "a DROP of a table, database or schema (irreversible)");
    if (/\btruncate\s+table\b/.test(low)) A("cc-sql-truncate", "a TRUNCATE, which removes every row in the table");
    if (/\bdelete\s+from\b/.test(low) && !low.includes(" where ")) A("cc-sql-delete-all", "a DELETE with no WHERE clause — it deletes every row");
    if (/\bupdate\s+\S+\s+set\b/.test(low) && !low.includes(" where ")) A("cc-sql-update-all", "an UPDATE with no WHERE clause — it rewrites every row");
    if (/\bgrant\s+all\b/.test(low)) A("cc-sql-grant-all", "a GRANT ALL — a broad privilege grant");
    // --- destructive filesystem ---
    if (/\brm\s+-[a-z]*r[a-z]*f|\brm\s+-[a-z]*f[a-z]*r/.test(low)) A("cc-rm-rf", "an rm -rf — a recursive, forced delete");
    if (/\bdd\s+if=/.test(low)) A("cc-dd", "a dd command, which can overwrite whole disks");
    if (/\bmkfs(\.\w+)?\b/.test(low)) A("cc-mkfs", "an mkfs, which formats a filesystem");
    if (/\bshred\b/.test(low)) A("cc-shred", "a shred — it irreversibly destroys file data");
    if (/\bwipefs\b/.test(low)) A("cc-wipefs", "a wipefs — it erases filesystem signatures");
    if (/\bchmod\s+-r\s+777\b/.test(low)) A("cc-chmod-777", "a chmod -R 777 — it makes a whole tree world-writable");
    if (/:\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:/.test(flat)) A("cc-forkbomb", "a shell fork bomb");
    // --- git history rewrite ---
    if (/\bgit\s+push\b[^;&|]*(--force\b|\s-f\b|--force-with-lease\b)/.test(low)) A("cc-git-force", "a git force push — it can overwrite shared history");
    if (/\bgit\s+reset\s+--hard\b/.test(low)) A("cc-git-reset", "a git reset --hard — it discards uncommitted work");
    if (/\bgit\s+clean\s+-[a-z]*f/.test(low)) A("cc-git-clean", "a git clean -f — it deletes untracked files");
    // --- remote code execution / supply chain ---
    if (/(curl|wget)\b[^|]*\|\s*(sudo\s+)?(bash|sh|zsh)\b/.test(low)) A("cc-pipe-shell", "a piped download run straight through a shell");
    if (/\beval\b[^;]*\$\(\s*(curl|wget)/.test(low)) A("cc-eval-remote", "eval of a downloaded script");
    if (/\b(python[0-9.]*|node|ruby|perl)\b[^;]*-e[^;]*\$\(\s*(curl|wget)/.test(low)) A("cc-interp-remote", "running a downloaded script through an interpreter");
    if (/\biwr\b[^|]*\|\s*iex\b|\biex\s*\(/.test(low)) A("cc-iex-remote", "PowerShell downloading and invoking a remote script");
    if (/\bpip[0-9]?\s+install\b[^;]*(http:\/\/|git\+)/.test(low)) A("cc-pip-untrusted", "a pip install from a URL / git source");
    if (/\bnpm\s+config\s+set\s+registry\s+http:\/\//.test(low)) A("cc-npm-registry", "pointing npm at an insecure (http) registry");
    // --- TLS / verification disabled ---
    if (/(curl|wget)\b[^|]*(\s-k\b|--insecure\b|--no-check-certificate\b)/.test(low)) A("cc-tls-curl", "disabling TLS certificate verification on a download");
    if (/node_tls_reject_unauthorized\s*=\s*0/.test(low)) A("cc-tls-node", "disabling TLS verification (NODE_TLS_REJECT_UNAUTHORIZED=0)");
    if (/stricthostkeychecking[= ]no/.test(low)) A("cc-ssh-nohostkey", "disabling SSH host-key checking");
    // --- infra destruction ---
    if (/\bkubectl\s+delete\b/.test(low)) A("cc-k8s-delete", "a kubectl delete — it removes live cluster resources");
    if (/\bterraform\s+destroy\b/.test(low)) A("cc-tf-destroy", "a terraform destroy — it tears down provisioned infra");
    if (/\bdocker\s+system\s+prune\b[^;]*-a|\bdocker\s+system\s+prune\s+-a/.test(low)) A("cc-docker-prune", "a docker system prune -a — it removes all unused images/volumes");
    if (/\bhelm\s+(delete|uninstall)\b/.test(low)) A("cc-helm-delete", "a helm uninstall — it removes a deployed release");
    // --- persistence / system tampering ---
    if (/>>?\s*~?\/?(\.bashrc|\.zshrc|\.bash_profile|\.profile)\b/.test(low)) A("cc-persist-rc", "writing to a shell startup file (a persistence vector)");
    if (/\bcrontab\b|>\s*\/etc\/cron/.test(low)) A("cc-persist-cron", "installing a cron job (a persistence vector)");
    if (/(>|\btee\b)\s*\/etc\/|\bvisudo\b|\/etc\/sudoers/.test(low)) A("cc-etc-write", "writing to a system config under /etc");
    if (/\bufw\s+disable\b|\biptables\s+-f\b|\bsetenforce\s+0\b/.test(low)) A("cc-security-off", "disabling a host firewall / SELinux");
    // --- secret exfiltration ---
    if (/(curl|wget|nc|ncat)\b/.test(low) && /(\.env\b|id_rsa\b|\.aws\/credentials|\.ssh\/id|\.pgpass|\.netrc|\$[a-z_]*secret|\$[a-z_]*token|\$[a-z_]*password)/.test(low)) A("cc-exfil", "sending environment or credential data to a remote host");
    if (/\benv\b\s*\|\s*(curl|wget|nc)/.test(low)) A("cc-exfil", "piping the environment to a network command");
    // --- sensitive read (advise) ---
    if (/\b(cat|less|head|tail)\b[^|;]*(\.env\b|id_rsa\b|\.aws\/credentials|\.ssh\/id|\.pgpass|\.netrc)|\/etc\/shadow/.test(low)) V("cc-read-secret", "reading a secret / credentials file");
  } else {
    // ---- file content being written ----
    if (/AKIA[0-9A-Z]{16}/.test(raw)) A("cc-secret-aws", "an AWS access key id being written into a file");
    if (/-----BEGIN\s+[A-Z0-9 ]*PRIVATE KEY-----/.test(raw)) A("cc-secret-privkey", "a private key being written into a file");
    if (/\bghp_[A-Za-z0-9]{30,}/.test(raw)) A("cc-secret-ghp", "a GitHub token being written into a file");
    if (/\bxox[baprs]-[A-Za-z0-9-]{10,}/.test(raw)) A("cc-secret-slack", "a Slack token being written into a file");
    if (/\bsk-ant-[A-Za-z0-9_-]{20,}/.test(raw)) A("cc-secret-anthropic", "an Anthropic API key being written into a file");
    if (/\bAIza[0-9A-Za-z_-]{30,}/.test(raw)) A("cc-secret-google", "a Google API key being written into a file");
    if (/\bsk-[A-Za-z0-9]{32,}/.test(raw)) A("cc-secret-openai", "an OpenAI-style API key being written into a file");
    // insecure code patterns (advise)
    if (/verify\s*=\s*False\b/.test(raw)) V("cc-code-verify", "TLS verification disabled in code (verify=False)");
    if (/InsecureSkipVerify\s*:\s*true/.test(raw)) V("cc-code-tlsskip", "TLS verification disabled in code (InsecureSkipVerify)");
    if (/rejectUnauthorized\s*:\s*false/.test(raw)) V("cc-code-rejectunauth", "TLS verification disabled in code (rejectUnauthorized:false)");
    if (/dangerouslySetInnerHTML/.test(raw)) V("cc-code-xss", "dangerouslySetInnerHTML (a possible XSS sink)");
    if (/\beval\s*\(/.test(raw)) V("cc-code-eval", "an eval() call");
    if (/child_process\.exec\s*\(/.test(raw)) V("cc-code-exec", "child_process.exec (a possible command-injection sink)");
    if (/#\s*nosec\b/.test(raw)) V("cc-code-nosec", "a suppressed security check (# nosec)");
    if (/pickle\.loads?\s*\(/.test(raw)) V("cc-code-pickle", "pickle deserialization (an RCE risk)");
    // CI / supply-chain files (advise)
    if ((/\.github\/workflows\//.test(flow) || /(^|\/)dockerfile/.test(flow)) && /(curl|wget)[^|]*\|\s*(bash|sh)/.test(low)) V("cc-ci-pipe", "a piped-download-to-shell inside a CI / Docker build file");
    if (/privileged\s*:\s*true/.test(raw)) V("cc-k8s-priv", "a privileged: true container spec");
  }

  if (!ask.length && !advise.length) return null;

  if (ask.length) {
    const [rid, why] = ask[0];
    const reason =
      "CID222 code-safety flagged this: it looks like " +
      why +
      ". This is a factual notice; the confirmation below is Claude Code's own. [rule: " +
      rid +
      "]";
    return {
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "ask",
        permissionDecisionReason: reason,
      },
    };
  }

  const notes = advise.slice(0, 3).map(([, w]) => w).join("; ");
  const ids = advise.slice(0, 3).map(([r]) => r).join(",");
  const note =
    "CID222 code-safety note: " +
    notes +
    ". The action was allowed; this is a recorded factual finding, not an instruction. [rule: " +
    ids +
    "]";
  return {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: note,
      additionalContext: note,
    },
  };
}

// Compose the assess request from the hook payload. Returns null when the
// tool/input is not gate-worthy (unknown tool, empty command) — then allow.
function assessBody(hook, ctx) {
  const tool = String((hook && hook.tool_name) || "");
  const ti = (hook && hook.tool_input) || {};
  let body = null;

  if (COMMAND_TOOLS.includes(tool)) {
    const cmd = ti.command || "";
    if (cmd.trim()) body = { kind: "command", command: cmd.slice(0, CAP) };
  } else if (tool === "Write") {
    body = { kind: "file", file_path: ti.file_path || "", content: (ti.content || "").slice(0, CAP) };
  } else if (tool === "Edit") {
    body = { kind: "file", file_path: ti.file_path || "", content: (ti.new_string || "").slice(0, CAP) };
  } else if (tool === "MultiEdit") {
    const edits = Array.isArray(ti.edits) ? ti.edits : [];
    const joined = edits.map((e) => (e && e.new_string) || "").join("\n");
    body = { kind: "file", file_path: ti.file_path || "", content: joined.slice(0, CAP) };
  } else if (tool === "NotebookEdit") {
    body = { kind: "file", file_path: ti.notebook_path || "", content: (ti.new_source || "").slice(0, CAP) };
  }
  if (body === null) return null;

  body.cwd = (hook && hook.cwd) || "";
  body.metadata = {
    tool: "claude-code",
    event: "pretool",
    tool_name: tool,
    repo: ctx.CID_REPO || "",
    branch: ctx.CID_BRANCH || "",
    session: process.env.CID_SESSION_ID || "",
    user_email: ctx.CID_EMAIL || "",
    plugin_version: ctx.CID_PLUGIN_VERSION || "",
  };
  return JSON.stringify(body);
}

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

async function main() {
  const hook = cid.parseJson(cid.readStdin());
  process.env.CID_SESSION_ID = cid.sessionFromHook(hook);
  cid.markHookRan(process.env.CID_SESSION_ID, "tool-gate"); // proof the hook ran

  if (process.env.CID_TOOLGATE_OFF === "1") return;

  // Repo/session context cached by SessionStart (identity only, never content).
  const ctx = cid.readCtx();

  if (process.env.CID_LOCAL_GATE_OFF !== "1") {
    let localOut = null;
    try {
      localOut = localGate(hook);
    } catch (_) {
      localOut = null; // a bad rule must never block a tool call
    }
    if (localOut) {
      emit(localOut);
      return;
    }
  }

  const body = assessBody(hook, ctx);
  if (!body) return;

  const verdictJson = await cid.assess(body);

  if (!verdictJson) {
    if (process.env.CID_FAIL_OPEN === "0") {
      emit({
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason:
            "CID code-safety service unreachable and this device is set to fail-closed. Retry once the CID gateway is reachable, or contact IT.",
        },
      });
    }
    return;
  }

  const v = cid.parseJson(verdictJson);
  if (!v) return;
  const d = String(v.decision || "").toLowerCase();
  const reason = String(v.reason || "").trim();
  const rule = String(v.matched_rule || v.rule_id || "").trim();

  if (d === "interrupt" || d === "deny" || d === "block") {
    let r = reason || "CID code-safety policy refused this action.";
    if (rule) r += " [rule: " + rule + "] — quote this rule id when reporting a false positive to IT.";
    emit({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: r,
      },
    });
  } else if (d === "ask") {
    let r = reason || "CID code-safety flagged this action as potentially risky.";
    if (rule) r += " [rule: " + rule + "]";
    emit({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "ask",
        permissionDecisionReason: r,
      },
    });
  } else if (d === "advise" || d === "warn") {
    let note = "CID222 code-safety note: " + (reason || "this action matched an advisory rule.");
    if (rule) note += " [rule: " + rule + "]";
    note += " The action was allowed; this is a recorded factual finding, not an instruction.";
    // permissionDecision allow + additionalContext: the note reaches the model
    // on Claude Code versions that support PreToolUse additionalContext and is
    // ignored harmlessly on older ones (the action proceeds either way).
    emit({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        permissionDecisionReason: note,
        additionalContext: note,
      },
    });
  }
  // allow / unknown → silent
}

cid.run(main);

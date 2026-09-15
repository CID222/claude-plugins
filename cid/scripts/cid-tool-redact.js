"use strict";
// PostToolUse hook (Read|Grep|Bash|PowerShell) — the DLP redactor. Reads the
// hook JSON on stdin, inspects the tool's primary text output via CID
// /inspect/v1 (through cid-common.js, so auth/context have one implementation),
// and on a REDACT verdict substitutes the redacted text back into that same
// field — preserving the tool's output shape, which Claude Code requires for
// `updatedToolOutput` on built-in tools. Log-only rules return ALLOW and are
// simply recorded. See docs/CLAUDE_CODE_BUILD_PLAN.md.
//
// Fail-open: any error leaves the tool output untouched (the tool has already
// run locally by the time this hook fires).

const cid = require("./cid-common.js");

// Return {get, set} for the tool's primary text field, shape-preserving.
// A null setter means the whole response is the string to replace.
function locate(resp) {
  if (typeof resp === "string") {
    return { get: () => resp, set: null };
  }
  if (resp && typeof resp === "object" && !Array.isArray(resp)) {
    if (typeof resp.stdout === "string") {
      // Bash / PowerShell
      return { get: () => resp.stdout, set: (t) => { resp.stdout = t; } };
    }
    const f = resp.file;
    if (f && typeof f === "object" && typeof f.content === "string") {
      // Read
      return { get: () => f.content, set: (t) => { f.content = t; } };
    }
    if (typeof resp.content === "string") {
      // generic
      return { get: () => resp.content, set: (t) => { resp.content = t; } };
    }
  }
  return { get: null, set: null };
}

// Tokens that precede the real command rather than being it.
const CMD_PREFIXES = new Set(["sudo", "env", "command", "nohup", "time", "exec", "cd", "then", "do"]);
const CMD_OK = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,31}$/;

// Python str.strip(chars) / lstrip(chars) equivalents.
function stripChars(s, chars) {
  let a = 0;
  let b = s.length;
  while (a < b && chars.includes(s[a])) a++;
  while (b > a && chars.includes(s[b - 1])) b--;
  return s.slice(a, b);
}
function lstripChars(s, chars) {
  let a = 0;
  while (a < s.length && chars.includes(s[a])) a++;
  return s.slice(a);
}

// The command a Bash line actually runs, e.g. `git` / `pytest` / `docker`.
//
// Naively taking the first whitespace token recorded shell noise as work:
// `TOK=$(cat f)` was logged as the command `TOK=$(cat`. Walk past assignments,
// substitutions and wrappers until something that looks like a program name
// appears, and give up rather than guess.
function commandWord(command) {
  // `cd x && git status` should report git, not cd or x, so each segment of the
  // line is considered until one names a program.
  for (const segment of String(command || "").split(/&&|\|\||;|\||\n/)) {
    const parts = segment.trim().split(/\s+/).filter(Boolean);
    let broke = false;
    for (const rawTok of parts) {
      let tok = stripChars(rawTok, "(){}!$\"'`");
      if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(tok)) {
        const rest = tok.slice(tok.indexOf("=") + 1);
        // FOO=bar cmd -> the value is data, keep walking. FOO=$(cmd ...)
        // -> the substitution is the work being done.
        if (!(rest.startsWith("$(") || rest.startsWith("`") || rest.startsWith('"$(') || rest.startsWith("'$("))) {
          continue;
        }
        tok = lstripChars(rest, "(){}$\"'`");
      }
      const segs = tok.split("/");
      tok = segs[segs.length - 1]; // /usr/bin/python3 -> python3
      if (!tok) continue;
      if (CMD_PREFIXES.has(tok)) {
        // These wrap or precede the real command; `cd` also eats its
        // argument, so drop the rest of this segment.
        if (tok === "cd" || tok === "then" || tok === "do") {
          broke = true;
          break;
        }
        continue;
      }
      return CMD_OK.test(tok) ? tok : "";
    }
    if (broke) continue;
  }
  return "";
}

// What this tool touched, as identifiers only.
//
// Read/Edit/Write carry a file_path; Grep carries a search path; Bash carries a
// command whose first word (git, npm, pytest) says what kind of work is going
// on. The rest of a Bash command line is dropped on purpose — flags and
// arguments routinely contain tokens, hosts and credentials, and none of that
// is needed to answer "what were they working on".
function workContext(data) {
  const tool = String((data && data.tool_name) || "");
  const ti = data && data.tool_input;
  let p = "";
  if (ti && typeof ti === "object") {
    if (typeof ti.file_path === "string") p = ti.file_path;
    else if (typeof ti.path === "string") p = ti.path;
    else if (typeof ti.command === "string") p = commandWord(ti.command);
  }
  return { toolName: tool, toolPath: p };
}

async function main() {
  const data = cid.parseJson(cid.readStdin());
  if (!data) return;

  const resp = data.tool_response;
  const { get, set } = locate(resp);
  if (!get) return;
  const text = get();
  if (!text || !text.trim()) return;

  // session_id comes from the hook payload (Claude Code does not export
  // CLAUDE_SESSION_ID to hooks) so the ctx-file lookup and telemetry both use
  // the real session.
  process.env.CID_SESSION_ID = cid.sessionFromHook(data);
  const { toolName, toolPath } = workContext(data);

  const verdictJson = await cid.inspect("response", text, "tool_use", { toolName, toolPath });
  if (!verdictJson) return; // fail-open: tool already ran locally; leave output as-is

  const v = cid.parseJson(verdictJson);
  if (!v) return;
  if (v.verdict !== "REDACT" || typeof v.redactedPayload !== "string") {
    return; // ALLOW (incl. flag/log-only) — nothing to substitute
  }

  const redacted = v.redactedPayload;
  let updated;
  if (set === null) {
    updated = redacted;
  } else {
    set(redacted);
    updated = resp;
  }

  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        updatedToolOutput: updated,
        additionalContext:
          "CID DLP redacted sensitive values in this tool output before you received them.",
      },
    }) + "\n"
  );
}

cid.run(main);

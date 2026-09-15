# CID222 Claude Code Plugin (`cid`)

Status: in-progress (Team-plan pilot; customer distribution model designed + tested)

**Product component, not an internal tool.** CID is sold to enterprises; this
plugin ships to *customer employees'* machines. Distribution therefore never
involves GitHub, the cid-core repo, or any manual git step on end-user
machines — everything is served from the customer's own deployed CID
appliance and pushed by customer IT. See
[docs/CLAUDE_CODE_PLUGIN_DISTRIBUTION.md](../docs/CLAUDE_CODE_PLUGIN_DISTRIBUTION.md)
for the full distribution design and status.

The plugin does **not** route traffic itself (Claude Code plugins cannot set
env vars) — routing comes from `ANTHROPIC_BASE_URL` in managed settings; the
plugin **verifies and reports** it every session and gives users `/cid:status`.

## Requirements

**Node.js only.** Every hook is a single CommonJS script with zero npm
dependencies, invoked through the hook config's exec form
(`"command": "node", "args": ["${CLAUDE_PLUGIN_ROOT}/scripts/…js"]`), which
spawns the executable directly with no shell on any platform. Node ships with
Claude Code, so there is nothing else to install — no `sh`, no `python3`, no
PowerShell.

> **Why v0.7.0 exists.** The shell build sent nothing from Windows. A hook
> `command` in *shell* form runs under `sh -c` on macOS/Linux but under **Git
> Bash on Windows, or PowerShell when Git Bash isn't installed**
> ([hooks reference](https://code.claude.com/docs/en/hooks)). PowerShell 5.1
> cannot parse the `sh … || powershell.exe …` fallback the old `hooks.json`
> used, and on the machines that did have Git Bash the scripts still needed
> `python3`. Only the preflight ever had a `.ps1`, so on Windows the prompt
> gate, tool gate, redactor, session audit and repo baseline were all dead.
> One Node implementation in exec form removes both failure modes.

## What it does (v0.7.0)

| Component | File | Behavior |
|---|---|---|
| SessionStart · preflight | `cid/scripts/cid-preflight.js` | Probes the real `/inspect/v1/claude-code` endpoint (the probe doubles as the session announcement: seat, repo, branch, session id). Emits a factual context note about inspection posture; warns on stderr on misconfiguration. Caches repo/session identity + session-start commit (`CID_HEAD`) for the other hooks. Never blocks. |
| SessionStart · repo baseline | `cid/scripts/cid-repo-baseline.js` | First Claude Code session on a repo **org-wide** queues one deep-path baseline audit: checks `/assess/v1/claude-code/repo-baseline` (dedup by `repo_id` = sha256 of the normalized remote URL), uploads `git archive HEAD` (tracked files only, ≤40 MB gz) in the background when the server says `baseline_needed`. Later sessions get the baseline status/summary as a context note. |
| UserPromptSubmit | `cid/scripts/cid-prompt-gate.js` | Prompt inspection via `/inspect/v1` — log-first; blocks only on BLOCK verdicts; MASK verdicts warn+pass (prompt text cannot be masked in place). Fail-open is **not silent** (v0.6.5): on an empty verdict it reads the HTTP status `inspect()` recorded and warns the user — rejected key (401/403), wrong host (404), unreachable (000), server error (5xx) — rate-limited per session (`CID_FAIL_OPEN_WARN_SEC`, default 900). |
| PreToolUse `Bash\|PowerShell\|Write\|Edit\|MultiEdit\|NotebookEdit` | `cid/scripts/cid-tool-gate.js` | **Code-safety tool gate.** Sends the command / about-to-be-written content to `/assess/v1/claude-code`; maps the decision to Claude Code's native contract: `allow` silent · `advise` allow + factual context note · `ask` native permission prompt · `interrupt` deny with reason + rule id. Fail-open default; `CID_FAIL_OPEN=0` for strict groups. |
| PostToolUse `Read\|Grep\|Bash\|PowerShell` | `cid/scripts/cid-tool-redact.js` | DLP redaction of tool output before it enters the model's context (via `/inspect/v1`), substituted back through `updatedToolOutput` in the tool's own output shape. |
| Stop · session audit | `cid/scripts/cid-session-audit.js` | Fire-and-forget POST of the session's diff (vs the session-start commit) + new untracked files to `/assess/v1/claude-code/session-audit` for a deep-path audit. Uploaded by a detached child process; never delays session end. |
| Skill | `cid/skills/status/SKILL.md` | `/cid:status` — inspection state + gateway health + policy reminder. |

Env contract: `CID_GATEWAY_URL`, `CID_INSPECT_KEY`, `CID_INSPECT_OFF=1` (all
inspection off), `CID_FAIL_OPEN` (default 1), `CID_FAIL_OPEN_WARN_SEC`
(default 900 — min seconds between fail-open warnings), `CID_INSPECT_TIMEOUT`,
`CID_KEY_FILE` (default `~/.cid/inspect-key` — per-machine key file fallback),
`CID_PREFLIGHT_OFF=1`, `CID_TELEMETRY_OFF=1` — plus code-safety knobs:
`CID_TOOLGATE_OFF=1`, `CID_ASSESS_URL`, `CID_ASSESS_TIMEOUT` (4 s),
`CID_AUDIT_OFF=1`, `CID_AUDIT_URL`, `CID_AUDIT_TIMEOUT` (15 s),
`CID_BASELINE_OFF=1`, `CID_BASELINE_URL`, `CID_BASELINE_MAX_MB` (40),
`CID_BASELINE_TIMEOUT` (120 s).

## Key delivery (three channels, most→least authoritative)

All hooks resolve the inspection key through one function, `inspectKey()` in
`cid/scripts/cid-common.js`:

1. **Managed settings `env.CID_INSPECT_KEY`** — the primary channel, but not
   perfectly reliable: a child session with `ANTHROPIC_BASE_URL` already in
   its ambient env can skip the settings fetch, leaving hooks keyless
   (observed live: SessionStart 401'd while PostToolUse in the same session
   authenticated). The v0.6.5 fail-open warning makes this visible.
2. **Per-machine key file** — `${CID_KEY_FILE:-~/.cid/inspect-key}`, dropped
   by IT (MDM/script), `chmod 600`, single `cid_key_…` token. Survives the
   managed-env gaps above; ignored unless it parses as a `cid_key_*` token.
3. **Baked default** — per-customer builds via
   `CID_GATEWAY=… CID_KEY=… ./claude-plugin/package.sh`, which rewrites the
   `const CID_DEFAULT_KEY = "…"` line in `cid-common.js` (and
   `const CID_DEFAULT_GATEWAY = "…"` in `cid-common.js` + `cid-preflight.js`). Zero client config; use for
   appliance-served customer marketplaces, never for builds pushed to a
   public repo.

## Server contract the gateway must serve (code safety — cid-core side)

The tool gate and audit hooks are wired against these routes (bearer =
`CID_INSPECT_KEY`; the gateway resolves the tenant group from it, applies the
license + group-override gate, and forwards to the cid-code-safety auditor
with server-set tenant headers):

| Route | Request | Response |
|---|---|---|
| `POST /assess/v1/claude-code` | `{kind:"command", command, cwd, metadata}` or `{kind:"file", file_path, content, cwd, metadata}` — `metadata` = `{tool, event, tool_name, repo, branch, session, user_email, plugin_version}` | `{decision: "allow"\|"advise"\|"ask"\|"interrupt", reason?, matched_rule?}` — group with code safety off ⇒ instant `allow` |
| `POST /assess/v1/claude-code/session-audit` | `{kind:"session_diff", base, head, diff, untracked:[{path, content?\|skipped}], metadata}` | `202` (job queued; report later via status/dashboard) |
| `POST /assess/v1/claude-code/repo-baseline` | `{repo_id, repo, branch, head, session}` | `{baseline_needed: bool, status?, summary?}` — dedup **by `repo_id`, org-wide**: only the first session on a repo ever gets `true` |
| `POST /assess/v1/claude-code/repo-baseline/upload` | `Content-Type: application/gzip` body = `git archive HEAD \| gzip`; headers `X-CID-Repo-Id`, `X-CID-Repo-Head` | `202` |

Unknown routes / older gateways: every hook fails open silently, so the plugin can
ship before the gateway side and simply activates as routes appear.

## Customer distribution (the product path)

Build the artifacts, put them on the appliance, customer IT pushes one file.
End users take **zero actions** and cannot disable the plugin.

```bash
./claude-plugin/package.sh          # → dist/claude/
# dist/claude/ is copied to the appliance, served statically at https://<cid>/claude/
```

| Artifact | Role |
|---|---|
| `plugins.git` | Bare git repo of the marketplace, served as **static files** (git dumb-HTTP — no git server software on the appliance). Claude Code clones it directly from the appliance. Verified end-to-end: static HTTP → `git clone` → `claude plugin validate` passes. |
| `managed-settings.template.json` | What customer IT deploys via MDM/GPO (or the Anthropic Team/Enterprise admin console). Replaces `CID_HOST`, drops the file, done: marketplace auto-registers from the appliance, `cid@cid222` force-installs (`enabledPlugins`), other marketplaces optionally blocked (`strictKnownMarketplaces`), routing pinned via `env`. Details: [deploy/claude-managed-settings/README.md](../deploy/claude-managed-settings/README.md). |
| `install.sh` + `cid-marketplace.zip` | Pilot fallback for unmanaged machines: `curl -fsSL https://<cid>/claude/install.sh \| CID_HOST=https://<cid> bash`. No git needed; re-run to update. |

Planned integration: the CID endpoint agent (Model A) drops
`managed-settings.json` itself and/or pre-seeds plugins offline via
`CLAUDE_CODE_PLUGIN_SEED_DIR` — no network fetch at all.

> ℹ️ The **session audit** and **repo baseline** hooks resolve their bearer as
> `CID_INSPECT_KEY` or the baked default only — they do not read the
> per-machine key file. This matches the shell build; the key-file channel
> covers the inspect and assess paths.

> ⚠️ In the template, keep `env.ANTHROPIC_BASE_URL` **unset** until the
> gateway's transparent Claude Code passthrough ships — today's cid-proxy
> translation path drops tool calls and beta headers. Visibility-only mode
> (`CID_GATEWAY_URL` alone) is the correct interim deployment.

## Internal dogfooding (this repo only — not the customer path)

The repo root doubles as a git marketplace for *our own team*:
`.claude-plugin/marketplace.json` + `.claude/settings.json`
(`extraKnownMarketplaces`/`enabledPlugins`) prompt anyone who trusts the
cid-core checkout to install `cid@cid222`. Teammates can also run
`/plugin marketplace add CID222/cid-core` — Claude Code clones into its own
cache; no checkout needed.

## Local test

```bash
node --check claude-plugin/cid/scripts/*.js   # syntax check (no deps to install)
claude --plugin-dir ./claude-plugin/cid       # then /cid:status
claude plugin validate ./claude-plugin/cid    # manifest check

# full distribution test (simulates the appliance):
./claude-plugin/package.sh /tmp/dist-claude
python3 -m http.server 8477 --directory /tmp/dist-claude &
git clone http://127.0.0.1:8477/plugins.git /tmp/clone-test
claude plugin validate /tmp/clone-test
```

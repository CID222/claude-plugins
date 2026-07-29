# CID222 Claude Code plugins

Private marketplace repository. This repo exists **only** to distribute the
`cid` plugin to employee machines through Claude's
[Organization settings → Plugins → Sync from GitHub](https://claude.ai/admin-settings/plugins).

> ⚠️ **Keep this repository private.** `cid/scripts/cid-common.sh` contains a
> live `cid_key_` (an *inspection* key scoped to the "Claude Code" tenant group
> — log/flag policy, not a provider credential). It is baked in so the plugin
> works with zero configuration. Rotate it in the CID dashboard if it leaks.

## Layout

```
.claude-plugin/marketplace.json   marketplace catalog (name: cid222)
cid/                              the plugin (name: cid)
├── .claude-plugin/plugin.json    version — clients only update when this changes
├── hooks/hooks.json              SessionStart, UserPromptSubmit, PostToolUse
├── scripts/                      POSIX sh + python3; cid-preflight.ps1 for Windows
└── skills/status/SKILL.md        /cid:status
```

Source of truth is [`CID222/cid-core`](https://github.com/CID222/cid-core) at
`claude-plugin/`. Changes are made there and mirrored here — do not diverge.

## What the plugin does

It does **not** reroute provider traffic (`ANTHROPIC_BASE_URL` is untouched).
On each prompt and on `Read`/`Grep`/`Bash` tool output, hooks POST the content
to `<gateway>/inspect/v1/claude-code`, which applies the tenant group's filter
profile (mostly log/flag, some values redacted, a few blocked) and records
work-visibility telemetry (repo, branch, session, seat email).

Baked defaults: gateway `https://api.cid222.live`, the group's inspection key.
Managed settings may override via `CID_GATEWAY_URL` / `CID_INSPECT_KEY`.

⚠️ `CID_GATEWAY_URL` must be the host that serves `/inspect/v1` — that is
`api.cid222.live`, **not** `proxy.cid222.live` (cid-proxy has no inspect
endpoint; pointing there makes every check 404 and fail open silently).

## Releasing

1. Change the code in `cid-core` at `claude-plugin/`, then mirror it here.
2. **Bump `cid/.claude-plugin/plugin.json` `version`** — installed clients pick
   up updates only when the version changes.
3. `git push`. Organization sync picks it up; members get it on their next
   session.

## Admin setup (one time)

*Admin settings → Plugins → Add plugins → Sync from GitHub* → install the Claude
GitHub App on this repository → select it → set the `cid` plugin's
**User access: Required**.

Members do not need access to this repository; organization sync packages the
plugin during distribution.

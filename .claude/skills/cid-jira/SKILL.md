---
name: cid-jira
description: CID product ticket workflow on Jira (furthersoft.atlassian.net, project CID) — create, pick up, resolve, and digest CID-* issues from any cid repo; pull context from git and the #cid222 Slack channel; enforce CID-Core docs conventions. Use when the user names a CID ticket ("CID-12", "şu ticket"), asks to create or resolve one ("ticket aç", "bunu ticket'a çevir", "close it"), wants a ticket made from a Slack thread, or asks for a CID backlog/status digest.
---

# CID Jira workflow

Glue between Jira (project CID), the cid repos, and the #cid222 Slack channel. The goal:
tickets that carry real context (code, diffs, Slack decisions) and get closed with real
evidence (root cause, files, verification), without the user hand-writing any of it.

## Constants

| Thing | Value |
|---|---|
| Site | `furthersoft.atlassian.net` |
| cloudId | `6e021e0e-43e0-4d16-af5a-f29fedfc87ac` |
| Project | `CID` (id 10132, team-managed) |
| Issue types | Epic `10136`, Task `10137`, Story `10138`, Feature `10139`, Bug `10140`, Subtask `10135` |
| Slack channel | `#cid222` = `C09TNCEUYBB` (private, workspace FurtherSoft `TCQ23B8BF`) |

**Access:** prefer the Atlassian Rovo MCP tools (`createJiraIssue`, `getJiraIssue`,
`editJiraIssue`, `addCommentToJiraIssue`, `searchJiraIssuesUsingJql`,
`getTransitionsForJiraIssue` → `transitionJiraIssue`) — each developer connects their own
Atlassian account on claude.ai. REST fallback (headless/cron, or MCP absent) uses your own
credentials — set `JIRA_EMAIL` (your Atlassian account email) and `JIRA_API_TOKEN`
(create one at https://id.atlassian.com/manage-profile/security/api-tokens) in your
environment or a local `.env` that is never committed:

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H 'Content-Type: application/json' \
  "https://furthersoft.atlassian.net/rest/api/3/..."
```

## Hard rules

- **Never post to Slack unprompted.** Creating/resolving a ticket does NOT imply announcing
  it in #cid222 — offer in chat, post only on explicit yes. (Standing team rule.)
- **Search before create.** Run a JQL dedupe search first; if a matching open issue exists,
  say so and link/comment instead of duplicating.
- **Tickets in English** (summary + description). If the source material (Slack thread, user
  message) is Turkish, keep the key Turkish sentence as a quote inside the description so
  nothing is lost in translation. Report back to the user in their language.
- **Short and direct** in anything that lands in Slack (channel style rule: a few words per
  item, tables/bullets, no prose walls).
- Repo work still obeys each repo's own `CLAUDE.md` (e.g. cid-core is Docker-only).

## Repo map (where a ticket's code lives)

The cid repos are sibling checkouts (adjust paths to your local layout):

| Ticket mentions | Repo |
|---|---|
| Gateway, guardrails/detection, dashboard, ML services, proxies, appliance, endpoint agent | `cid-core` (module READMEs per `CLAUDE.md`) |
| Browser extension, MV3, Shadow-AI browser enforcement | `cid-extension` |
| Embeddable chatbot / bot-builder | `cid-chat` |
| Claude Code plugin, code-safety gate | `cid-core/claude-plugin/` + `cid-code-safety` |

## Verb: create a ticket

1. **Dedupe:** `searchJiraIssuesUsingJql` with `project = CID AND statusCategory != Done AND text ~ "<keywords>"`.
2. **Infer type:** defect → Bug; new capability → Feature; refactor/chore/docs → Task; user-visible
   scenario framing → Story; multi-week theme → Epic (ask before creating Epics).
3. **Auto-context — this is the point of the skill.** Pull whatever applies, don't ask for what
   you can read: current repo + branch + uncommitted diff summary; failing test output; the
   relevant `docs/PLAN_*.md` (link it, and note its `Status:` line); module path
   (e.g. `cid-nestjs-gateway/endpoint-agent/`); Slack thread permalink if that's the source.
4. **Labels:** repo name (`cid-core`, `cid-extension`, `cid-chat`, `appliance`) + area when
   obvious (`guardrails`, `dashboard`, `endpoint-agent`, `inline-proxy`, `licensing`, `docs`).
5. Create, then report the key + browse URL (`https://furthersoft.atlassian.net/browse/CID-N`).

Description skeleton: **What / Why now / Evidence (diff, logs, screenshot, Slack link) /
Done when** — 4 short blocks, no boilerplate headings beyond that.

## Verb: ticket from a Slack thread

"Şu thread'den ticket yap": `slack_read_thread` on the message, extract the *decision or
problem* (not a transcript), create per the rules above with the thread permalink under
Evidence. If the thread names an owner, set assignee (`lookupJiraAccountId`). Do not reply
in the thread unless asked.

## Verb: pick up / work a ticket

1. Fetch issue + comments (`getJiraIssue`). Check attachments — download and *look* at
   screenshots (REST fallback above), they often carry the only real evidence.
2. **Recall before investigating:** search your Claude Code memory
   (`~/.claude/projects/*/memory/`) for the symptom — many CID subsystems have prior
   root-cause findings.
3. Locate the repo (table above), read the module README first (cid-core rule).
4. Branch: `feat/CID-<n>-<slug>` — for cid-core, cut off `origin/pre-main`; never work
   directly on long-lived branches (standing branching rule).
5. Work the change per the repo's conventions. Comment meaningful progress/decisions back to
   the ticket so Jira stays the record — terse, factual comments.

## Verb: resolve

1. **Docs gate (cid-core):** if the change touched endpoints/guards/services, the module
   README must be updated in the same change; new `docs/` file → new row in `docs/README.md`;
   an executed plan doc gets its `Status:` line updated. Don't close a ticket that fails this.
2. Closing comment: root cause → files changed → how verified → commit/PR links. If it turned
   out invalid/duplicate/already-fixed, say that and close accordingly instead of inventing work.
3. `getTransitionsForJiraIssue` → `transitionJiraIssue` to Done (transition names in
   team-managed projects vary — read them, don't hardcode).

## Verb: digest / status

`project = CID AND statusCategory != Done ORDER BY updated DESC` (+ variants: stale = not
updated in 14d, unassigned, by label). Output a short table in chat. Only push to #cid222 or
the Start Here canvas if explicitly asked; canvas edits use targeted section replace
(read canvas → `section_id` → replace), never full-body replace.

## What this skill does NOT do

- No WhatsApp integration — there is no ToS-safe bot path into a personal group. If ever
  needed, it's Jira Automation → Twilio one-way pings, configured in Jira, not here.
- No Confluence — CID engineering docs live in-repo (module READMEs + `docs/`); the current
  Atlassian connection has Jira scopes only.
- No auto-posting to Slack, ever (see hard rules).

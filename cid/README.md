# CID222 Gateway Connector (`cid`)

Claude Code plugin: session preflight, prompt/tool-output inspection, code-safety
gating and the `/cid:status` skill. Full documentation — install, key delivery,
env contract, server contract — is in [`../README.md`](../README.md).

## Versions

## 0.7.1

- Every hook now writes a hook-ran marker (`<tmpdir>/cid-claude-code/<session-id>.json`) before any opt-out, so there is local proof that the hook process actually ran.
- `/cid:status` reads that marker and reports "Active" only when a hook ran in this session; where no hook ran (the Claude Desktop app's Code tab) it now says "Not active (no hooks)" instead of falsely claiming inspection.

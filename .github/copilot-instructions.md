# Copilot instructions — cc-tailsync

Part of the **[cc-mods](https://github.com/cc-mods)** CrossCode suite (wireless save sync).

📓 **Read the suite agent docs first:**
**[`cc-mods/cc-agentdocs`](https://github.com/cc-mods/cc-agentdocs)** (private; org members only) is the
source of truth for hard-won findings — start at its
[`AGENTS.md`](https://github.com/cc-mods/cc-agentdocs/blob/main/AGENTS.md). Most relevant here:
- [`cc-tailsync.md`](https://github.com/cc-mods/cc-agentdocs/blob/main/cc-tailsync.md) — architecture,
  per-OS save paths, the server, `integrate-ios.sh`, the launchd/TCC gotcha, Windows Scheduled Task.
- [`cc-ios.md`](https://github.com/cc-mods/cc-agentdocs/blob/main/cc-ios.md) — the `SaveSyncProvider`
  seam this consumes.

**When you learn something durable, add it to `cc-mods/cc-agentdocs`** and keep this pointer intact.

## What this is

A monorepo: `Sources/CCTailsync` (a SwiftPM library — the iOS sync client), `servers/`
(cross-platform `save-server.py` + macOS launchd + Windows Scheduled Task wrappers), and `tools/`
(`setup-sync.sh`, USB `save-sync.sh`, `integrate-ios.sh`). CrossCode's `cc.save` is byte-identical
between desktop and iOS; sync is **newest-wins** (mtime + sha256 short-circuit).

## Must-not-break

- **One-way dependency:** `CCTailsync` depends on **nothing** from cc-ios. It matches cc-ios's
  `SaveSyncProvider` signatures structurally so the conformance is a 1-line extension added by
  `integrate-ios.sh`. Never `import` cc-ios here.
- Sync must be **fail-safe**: no config / unreachable server → silent no-op, never blocks the game.
- **Never commit** `cc-sync.json`, real IPs/tokens, or save data (git-ignored — keep it so).
- Keep the server stdlib-only and cross-platform (Windows/macOS/Linux save-path detection).
- `integrate-ios.sh` edits files **inside a cc-ios checkout** — keep its add/remove round-trip
  idempotent (verified against the real `project.yml`).

## Verify

`bash -n` the shell scripts (use Git bash on Windows); `python -m py_compile servers/save-server.py`;
PowerShell parse `servers/windows/save-server.ps1`. Exercise the server against a **throwaway copy**
of a save (never the real `cc.save`): `/status` hash, `GET` round-trip, `PUT` + `.backup`, token
auth. Swift builds need macOS (`swift build`).

> No GitHub release workflow here — it's a library + tooling repo, not a packaged `.ccmod`.

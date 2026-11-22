---
name: recall
description: "Rebuild recent working context on a topic from pi sessions, Ledgers, reports, and GitHub state before resuming work. Use for /recall, 'recall my work on X', 'where did I leave off', or 'what have I been working on'."
---

# Recall

Rebuild the user's recent working context on a topic and hand back a tight current-state brief before starting or resuming work. Keep reading bounded to in-scope threads, then stop.

## Scope

Lock the scope before searching and state it back:
- **Topic**: the named feature, issue, or area (or general activity if unnamed).
- **Window**: explicit range, defaulting to the last 7 days. Keep "all" as all—never silently shrink it.
- **Project**: the current repository only. Read another project's sessions only when the user explicitly asks.

If the user already supplied a complete state capsule (branch, paths, current state), use it and skip mining.

## Gather

1. **Pi sessions**: look in `~/.pi/agent/sessions/<cwd-slug>/`, where `<cwd-slug>` encodes the project path with `/` replaced by `-` and wrapped in `--` (e.g. `/Users/me/dotfiles` → `--Users-me-dotfiles--`). List by modification time (`ls -t`), skip the active session and noise, and search with `grep` and `jq` over JSONL rather than reading whole files. Extract only matching regions: goal, decisions, open threads, blockers, and artifacts (PRs, issues, branches), citing each session file.
2. **Manager state**: read `.agents/ledger.md` and relevant files in `.agents/reports/` at the main checkout's root.
3. **Live state & shared record**: verify every surfaced branch, PR, and issue against live `git` and `gh` (`gh pr list`, `gh issue list`, `gh issue view`, `gh pr view`). Check for merged work, reverts, open PRs, and recurring issue comments. Null results are findings—record them.

## Reply

Stay on the named topic; exclude adjacent work unless it blocks this one. Cite session IDs and PR/issue numbers.

- **Capsule**: one paragraph stating what this work is and where it stands overall.
- **Threads**: one line per thread, each prefixed with exactly one status tag:
  - `[merged #N]`
  - `[open PR #N]`
  - `[in flight <branch>]`
  - `[verified, uncommitted]`
  - `[reverted #N]`
  - `[planned]`
  Every thread carries a tag; cut detail before cutting threads.
- **Recurring problems**: up to 5 recurring bugs, blockers, or reverted attempts so the next pass starts where the last one stopped.
- **Next move**: the single most concrete next action.

---

*Adapted from pstack (`skills/recall/SKILL.md`), Copyright (c) 2026 Lauren Tan, MIT License.*

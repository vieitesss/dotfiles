---
name: subagents
description: Spawn a Pi subagent and wait for its result. Use when handing off a research, implement, or write task to a child agent.
---

Run `scripts/subagent.py` from the herdr pane where the parent Pi runs.

```bash
scripts/subagent.py "the task for the child" \
  [--kind research|implement|write] [--model MODEL] [--effort LEVEL] \
  [--skill NAME]... [--cwd DIR] [--workspace ID] \
  [--timeout MS] [--dry-run]

scripts/subagent.py --close TAB_ID
```

It creates a herdr tab in the calling agent's workspace (from
`HERDR_WORKSPACE_ID`, not whichever workspace is focused in the UI), starts Pi
there, prompts it with the task, prints the tab id, and exits. The parent does
not wait for the child (see Waiting for the subagent). Close the tab later with
`--close` and the tab id from launch. Launch failures exit 2 and leave the tab
open. `--workspace` overrides the target workspace.

Jev picks `--kind`, `--model`, `--effort`, and the skills (it needs
`TYPESAFE_API_KEY` and falls back to `--kind implement` on error). Each flag
overrides just its own field, so Jev is skipped only when all four are given.
`--dry-run` prints the chosen profile without launching. The child's prompt
names the skills to use and tells it it can reach the parent via pi-intercom.

## Waiting for the subagent

After `subagent.py` returns, do nothing and end your turn. No sleep loops, no
`herdr pane read`, no tab or agent status checks, no `intercom pending` polling.

The only thing that resumes you is the subagent's pi-intercom message: its final
result arrives as a plain message; its questions arrive as intercom asks you
answer with `intercom reply`.

Close the tab with `--close` only after you have the result.

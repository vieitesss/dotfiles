---
name: subagents
description: Spawn a Pi subagent and wait for its result. Use when handing off a research, implement, or write task to a child agent.
---

Run `scripts/subagent.py` from the herdr pane where the parent Pi runs.

```bash
scripts/subagent.py "the task for the child" \
  [--kind research|implement|write] [--model MODEL] [--effort LEVEL] \
  [--skill NAME]... [--cwd DIR] [--workspace ID] \
  [--timeout MS] [--lines N] [--keep] [--dry-run]
```

It creates a herdr tab, starts Pi there, prompts it with the task, waits until it
is done or blocked, prints its recent output, and closes the tab. The tab stays
open when the child blocks, when the launch fails, or with `--keep` (those
failures exit 2).

Jev picks `--kind`, `--model`, `--effort`, and the skills (it needs
`TYPESAFE_API_KEY` and falls back to `--kind implement` on error). Each flag
overrides just its own field, so Jev is skipped only when all four are given.
`--dry-run` prints the chosen profile without launching. The child's prompt
names the skills to use and tells it it can reach the parent via pi-intercom.

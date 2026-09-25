---
name: subagents
description: Spawn a Pi subagent and wait for its result. Use when handing off a research, implement, or write task to a child agent.
---

Run `scripts/subagent.py` from the herdr pane where the parent agent (Pi or
Claude) runs.

```bash
scripts/subagent.py "the task for the child" \
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

Jev always picks the subagent kind, model, and thinking effort, and by default
picks the skills too. `--skill` overrides Jev's skill choices.
Jev needs `TYPESAFE_API_KEY`; if it is unavailable, the launcher uses the
`implement` kind and pi's default model and effort. `--dry-run` prints the
chosen profile without launching. The child's prompt names the skills to use
and tells it how to reach the parent.

A `claude-code/<model>` model starts Claude Code instead of Pi.

The child reports over pi-intercom only when both parent and child are Pi.
Otherwise (a Claude parent, or a Claude child) it reports through herdr: it
types into your pane with `herdr agent prompt`, so its messages arrive as
prompts starting with `[subagent-...]`.

## Waiting for the subagent

After `subagent.py` returns, do nothing and end your turn. No sleep loops, no
`herdr pane read`, no tab or agent status checks, no `intercom pending` polling.

The only thing that resumes you is the subagent's message. Over pi-intercom,
its final result arrives as a plain message and its questions arrive as
intercom asks you answer with `intercom reply`. Over herdr, its result or
question arrives as a `[subagent-...] TASK COMPLETE:` or `QUESTION:` prompt;
answer its questions with `herdr agent prompt <agent-name> "..."`.

Close the tab with `--close` only after you have the result.

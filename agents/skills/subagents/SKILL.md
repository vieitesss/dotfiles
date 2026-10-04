---
name: subagents
description: Launch a child agent in its own tab, exchange messages with it, and close it. Use when handing off a research, implement, or write task to a child agent.
---

Launching is the manager's move: the `manager` skill decides when to delegate
and what a brief carries. A child does its own task and reports; the launcher
already tells it so.

Run `scripts/subagent.py` from the herdr or tmux pane where the parent agent
(Pi or Claude) runs.

```bash
scripts/subagent.py "$(cat BRIEF_FILE)" \
  [--skill NAME]... [--cwd DIR] [--workspace ID | --project DIR] \
  [--timeout MS] [--dry-run]

scripts/subagent.py --notify PANE "message"   # prompt a pane (tmux)
scripts/subagent.py --close TAB_ID
```

It detects the multiplexer (herdr if `HERDR_ENV` is set, else tmux) and
creates a tab for the child in the calling agent's workspace:

- herdr: a tab in the workspace from `HERDR_WORKSPACE_ID`, not whichever
  workspace is focused in the UI.
- tmux: a window in the session of `TMUX_PANE`, not whichever session is
  attached.

It starts Pi there, prompts it with the task, prints the tab id (a tmux window
id such as `@18`) and the child's pane id, and exits. Keep both: the pane id
addresses follow-ups, the tab id closes the tab. Launch failures exit 2 and
leave the tab open. `--workspace` overrides the target: a herdr
`workspace_id`, or a tmux session name or id.

## Profile

Jev always picks the subagent kind, model, and thinking effort, and by default
picks the skills too. `--skill` overrides Jev's skill choices.
Jev needs `TYPESAFE_API_KEY`; if it is unavailable, the launcher uses the
`implement` kind and pi's default model and effort. `--dry-run` prints the
chosen profile without launching. A `claude-code/<model>` model starts Claude
Code instead of Pi.

## Workspaces

`--project DIR` puts the child in DIR's own session instead, and runs it in DIR
unless `--cwd` says otherwise. The launcher runs
`nexo --json --backend <mux> open --no-focus DIR`, which creates the session
(or herdr workspace) without switching your view to it. DIR must be a project
nexo discovers.

Create a fresh worktree with:

```bash
nexo --json worktree create --no-focus --new-branch --add-parent \
  REPO BRANCH <repo-parent>/<repo>-wt/<name>
```

The branch starts from REPO's current HEAD, so update main first. The command
opens the worktree without focus; pass its `.container.id` as `--workspace`.
`--add-parent` adds the `-wt` folder to nexo's paths, so `--project` then
works for every worktree in it.

A fresh worktree holds tracked files only. Pass untracked project skills
(`.agents/skills/…`) by their absolute path in the main checkout.

## Messages

The child reports over pi-intercom only when both parent and child are Pi:
its result arrives as a plain message, its questions as intercom asks you
answer with `intercom reply`. Otherwise it types into your pane, so its
messages arrive as prompts:

- `[subagent-…] TASK COMPLETE: <summary or report path>` — the result.
- `[subagent-…] QUESTION: <question>` — it waits for your answer.

Any other `[subagent-…]` message that asks for a choice is a question too.
Answer, or send a follow-up after a result, with
`herdr agent prompt <agent-name> "..."` in herdr, or
`scripts/subagent.py --notify <child-pane-id> "..."` in tmux. A follow-up
earns a fresh TASK COMPLETE.

## Waiting

After launching or messaging a child, end your turn. Its next message resumes
you; that message is the only signal to act on, so leave its pane, tab status
and intercom queue unread.

Close the tab with `--close` once you have accepted the result.

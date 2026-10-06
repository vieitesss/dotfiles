---
name: subagents
description: Launch a Subagent for one Stage of a Work Item in its own tab, exchange messages with it, and close it. Use when the Manager delegates a Stage.
---

Launching is the Manager's move: the `manager` skill decides when to delegate
and what a brief carries. A Subagent runs one Stage and reports; the launcher
already tells it so.

Run `scripts/subagent.py` from the herdr or tmux pane where the Manager (Pi or
Claude) runs.

```bash
scripts/subagent.py --stages                 # Stages, their skills and models

scripts/subagent.py --stage STAGE [--axis AXIS] --item ITEM "$(cat BRIEF_FILE)" \
  [--cwd DIR] [--workspace ID | --project DIR] [--timeout MS] [--dry-run]

scripts/subagent.py --notify PANE "message"   # prompt a pane (tmux)
scripts/subagent.py --close TAB_ID
```

It detects the multiplexer (herdr if `HERDR_ENV` is set, else tmux) and
creates a tab for the Subagent in the calling agent's workspace:

- herdr: a tab in the workspace from `HERDR_WORKSPACE_ID`, not whichever
  workspace is focused in the UI.
- tmux: a window in the session of `TMUX_PANE`, not whichever session is
  attached.

It starts the agent there, prompts it with the brief, prints the tab id (a
tmux window id such as `@18`) and the Subagent's pane id, and exits. Keep
both: the pane id addresses follow-ups, the tab id closes the tab. Launch failures exit 2 and
leave the tab open. `--workspace` overrides the target: a herdr
`workspace_id`, or a tmux session name or id.

## Stage and profile

`--stage` decides the Subagent's skills and instructions; Review also takes
`--axis`. A Stage that pins a model (Write, Review) uses it; for the rest,
Jev picks the model, and Jev picks the thinking effort for every Stage. Jev
needs `TYPESAFE_API_KEY`; without it the launcher uses the default model and
its default effort. A `claude-code/<model>` model starts Claude Code instead
of Pi. `--dry-run` prints the profile, the Subagent's name, and its report
path without launching.

The launch fails before opening a tab when a Stage's skill is not installed
for `--cwd`, or when its `SKILL.md` sets `disable-model-invocation: true`, so
a Subagent could not load it. Prove loads the repo's `verify-*` skills, so it
needs at least one.

## Reports

Each Subagent writes its full report to
`.agents/reports/<item>-<stage>[-<axis>].md` in the main checkout, even when
it works in a worktree, and sends a one-line TASK COMPLETE pointing at it.
The launcher adds `.agents/ledger.md` and `.agents/reports/` to the repo's
`.git/info/exclude`.

## Workspaces

`--project DIR` puts the Subagent in DIR's own session instead, and runs it in
DIR unless `--cwd` says otherwise. The launcher runs
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

A fresh worktree holds tracked files only. The launcher also finds untracked
project skills (`.agents/skills/…`) in the main checkout and hands every
Subagent its skills by absolute path.

## Messages

Every message starts with the Subagent's tag, `[subagent-<stage>-<pid> ·
<item> · <stage>]`, so you always know which Work Item and Stage it is about.
The Subagent reports over pi-intercom only when both it and the Manager are
Pi: its report arrives as a plain message, its questions as intercom asks you
answer with `intercom reply`. Otherwise it types into your pane, so its
messages arrive as prompts:

- `[…] TASK COMPLETE: <summary>`: the Stage is done; the report file holds
  the detail.
- `[…] QUESTION: <question>`: it waits for your answer.

Any other tagged message that asks for a choice is a question too. Answer, or
send a follow-up after a report, with `herdr agent prompt <agent-name> "..."`
in herdr, or `scripts/subagent.py --notify <subagent-pane-id> "..."` in tmux.
A follow-up earns a fresh TASK COMPLETE.

## Waiting

After launching or messaging a Subagent, end your turn. Its next message
resumes you; that message is the only signal to act on, so leave its pane,
tab status and intercom queue unread.

Close the tab with `--close` once you have accepted the report.

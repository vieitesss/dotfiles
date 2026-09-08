---
name: pi-subagent
description: Spawn subagent sessions for research, implement, or write work, including a plan/work/critique arc for multi-step implement. Use when classifying a user task and handing it to a child, or when a subagent needs follow-up, status, wait, listing, stop, or a plan executed node-by-node and critiqued.
---

# Pi Subagent

Resolve `scripts/pi-subagent.sh` relative to this `SKILL.md`. Run it from the parent Pi process's current working directory.

Subagent sessions talk back over `pi-intercom`. Each child gets a `contact_supervisor` tool bound to the parent session, sends a `TASK COMPLETE:` completion report when it finishes, and may escalate mid-task. Completion reports are the result channel; the file artifacts are crash forensics.

**Spawn surface.** When `HERDR_ENV=1`, load `using-herdr` and follow Herdr spawn. Otherwise invoke the helper from this supervisor (tmux or headless).

## Supervisor routing

Classify, spawn, sequence, and talk to the user. Grill or clarify freely. Answer when no lookup or edits are needed. Spawn for any file change. Children execute the assigned task directly; they do not spawn further agents.

1. Classify the user task as one **kind**: `research` | `implement` | `write`. One kind per child; sequence multiple kinds yourself.

   This step is complete when exactly one kind is chosen.

2. Spawn the matching **session** from the table (`--agent` = Session). Research and write: `start` with that row's `--model` and `--effort` (no arc). Implement: the arc when there is more than one step; a trivial implement is `start` (implementer default), then reviewer.

   After every implementer finish, spawn **reviewer** — `critique` on the arc ID, or `start --agent reviewer` with the reviewer row's `--model` and `--effort` after a trivial `start`. Reviewer is a successor, not a user kind, and never runs after plan.

   This step is complete when the spawn path is chosen, every non-implementer `start` carries the row's Model and Effort, and reviewer is queued after implement.

3. Attach skills from the Skill column. Repeat `--skill PATH` on later turns that still need them. Add any extra skills the user asked for.

   This step is complete when every listed skill is on the launch, or correctly omitted.

| Session | Purpose | Model | Effort | When | Skill |
|---|---|---|---|---|---|
| researcher | Repo recon: relevant files, entry points, data flow, risks, and where to start. | `github-copilot/gpt-5.6-luna` | `max` | user kind = research | none |
| implementer | Change code, not standalone documentation. | `github-copilot/grok-4.6` | `xhigh` | user kind = implement (default) | `implement` only if the repo has a test runner |
| writer | Standalone documentation. | `github-copilot/grok-4.6` | `xhigh` | user kind = write | `writing-for-agents` only for skills / AGENTS.md / CLAUDE.md |
| reviewer | Judge an implementer's work after that implementer finishes. | `github-copilot/kimi-k3` | `high` | after every implementer finish | none |
| planner | A concrete implementation plan from existing context. Read and plan, not edit. | `github-copilot/grok-4.6` | `xhigh` | multi-step implement only | none |

**Gate.** implement → reviewer → writer (if any). Writer waits for PASS. FIX: respawn implementer, then reviewer again.

**Ownership.** Writer owns standalone docs. Implementer may touch comments and docstrings in the code change. PR and commit text stay with the supervisor. CONTEXT.md and ADRs use `domain-modeling`, not `writing-for-agents`.

Web/docs investigation is the `research` skill, not a kind. `/review` is the `review` skill, not the reviewer session.

Retarget a kind's profile with `/update-subagents`.

Helper `start` defaults to the implementer row. On every other `start` (researcher, writer, reviewer), pass that row's `--model` and `--effort`. An explicit override must provide both `--model` and `--effort`; ask for the missing member of a partial override.

## Delegate

1. Choose execution mode.
   - Prefer `--async`: completion reports arrive inline via intercom, so the parent keeps doing independent work and consumes results as they land.
   - Use foreground mode only when the parent's very next step depends on the result.
   - Permit one editing subagent at a time in the active checkout; read-only tasks may overlap.
   - Each delegated task gets its own session ID.

   This step is complete when the mode is chosen and no editing subagent conflicts with an active one.

2. Write a self-contained prompt file. Include the task, relevant conversational context, constraints, expected output, and whether the child may edit. The child starts with fresh conversational context plus normal `AGENTS.md`/`CLAUDE.md` discovery.

   This step is complete when the prompt file alone contains everything the child needs.

3. If the spawn path is the arc, follow Arc below. Otherwise resolve your intercom presence name, then launch. When `HERDR_ENV=1`, follow Herdr spawn and `pane run` this same helper command in the new pane; otherwise run it here.

   ```typescript
   intercom({ action: "list" })   // read the "Current session" row
   ```

   ```sh
   "$helper" start [--async] [--orchestrator-target NAME] [--agent ROLE] \
       [--model MODEL --effort LEVEL] [--skill PATH] PROMPT_FILE
   ```

   Pass `--model` and `--effort` from the table row on researcher, writer, and reviewer `start`. Omit them only for implementer `start`.
   - If your session is named, pass `--orchestrator-target NAME` with that name so completion reports and escalations route to you.
   - If it is unnamed (a `subagent-chat-...` alias), omit the flag; the helper derives the alias from the parent session.
   - Capture `id`, `session` (the `session.jsonl` path), `turn`, and prompt/result/stderr/exit-code paths. On Herdr spawn, read them from the pane; the Herdr pane is the watch surface. On the non-Herdr path the helper also prints exactly one `watch=` line: tmux success is `watch=tmux tmux_session=... window=subagents pane=...` — `tmux_session` is this supervisor's tmux session name, not the jsonl path. Headless is `watch=none reason=tmux-not-installed` or `watch=none reason=not-inside-tmux`. A selected-tmux setup failure (including an unmarked or duplicate `subagents` window) exits nonzero with no child and no headless fallback. The child launches with the parent session's `PI_SESSION_ID`/`PI_MODEL`/etc. bash-tool metadata stripped, plus bridge metadata that binds its `contact_supervisor` tool to you.

   This step is complete when those values are captured.

4. Consume results.
   - Completion reports arrive as inline intercom messages prefixed `TASK COMPLETE:` — treat the report (outcome, what changed or was found, key files, what remains) as the result.
   - `need_decision` escalations block the child with a 10-minute timeout: reply promptly with `intercom({ action: "reply", message: "..." })`. Answer `interview_request` escalations with the documented `{ "responses": [...] }` JSON. Read `UPDATE:` progress messages; no reply required.
   - An expected report that never arrives is the failure signal: run `wait`/`status ID`, then inspect the returned stderr path and `turn-NNN.result.partial.md`. A failed turn has no result artifact.
   - Foreground: check the command exit status first, then consume the report.

   This step is complete when dependent work uses a successful result, or failure diagnostics have been reported.

## Continue or control a session

```sh
# Continue the same conversation and model profile; reuses the supervisor target; each turn gets its own Herdr pane or tmux watch pane
"$helper" follow-up ID [--async] [--orchestrator-target NAME] [--agent ROLE] [--skill PATH] PROMPT_FILE

# Replace the persisted profile for this and later turns
"$helper" follow-up ID --model MODEL --effort LEVEL PROMPT_FILE

# Observe or control delegated work
"$helper" status ID
"$helper" wait ID
"$helper" list
"$helper" stop ID
```

`list` reports sessions. On tmux it also sweeps extra completed watch panes, keeping the last completed pane as the watch window's anchor. `stop` sends a termination signal; the matching watch pane stays as a completed pane (see Watch window). Use `wait` or `status` afterward to observe completion. `status` / `wait` / `list` / `stop` run on this supervisor even when children were started via Herdr spawn.

Sessions persist under `./.pi-subagent-runs/<id>/`. Remove an exact session directory only when the user explicitly requests deletion.

## Arc: plan -> work -> critique

Use this arc only for multi-step **implement**. Skip it for research and write. A trivial implement is `start` as implementer, then `start --agent reviewer` with the reviewer row's `--model` and `--effort`. Reviewer never runs after plan. `plan` / `work` / `critique` are child-starting launches: same spawn surface as `start`.

The plan file is the arc's only state: `.pi-subagent-runs/<id>/plan.md`, a checklist of nodes with acceptance criteria. Which node is next and how much is done are always read from it, never tracked separately.

1. **Plan.** Write a prompt that tells the planner to produce a plan only — do not implement anything — then launch it. It explores read-only and writes the plan:

   ```sh
   "$helper" plan [--async] [--orchestrator-target NAME] [--skill PATH] PROMPT_FILE
   ```

   Uses the planner row unless overridden. The planner's session has no `edit`/`write` tools, so it cannot implement even if it tries. Read `plan.md` back and show it to the user; proceed once they approve it or ask for edits.

2. **Work.** Drive the implementer one node at a time; each call implements the next unchecked node and ticks it off:

   ```sh
   "$helper" work ID [NODE...] [--async] [--model MODEL --effort LEVEL] [--agent ROLE]
   ```

   `NODE` words are an optional hint (e.g. a node number) when a specific node should go next instead of the default "next unchecked". Defaults to the implementer row regardless of what the planner used, so pane titles/reports reflect the current stage; pass `--model`/`--effort`/`--agent` to use something else for that turn. The implementer may take a following node in the same turn only when it is trivially small and strictly sequential — otherwise one node per call. Repeat until `status ID` reports every node checked (`plan=k/n`). A `need_decision` escalation mid-node behaves like any other subagent escalation: reply, then call `work` again to resume.

3. **Critique.** Launch a fresh, read-only reviewer that judges the plan against what was actually done:

   ```sh
   "$helper" critique ID [--async] [--orchestrator-target NAME] [--model MODEL --effort LEVEL]
   ```

   Uses the reviewer row by default — same command, same read-only strip as plan. Like the planner, its session has no `edit`/`write` tools. It reads `plan.md`, the implementer's artifacts, and (inside a Git repo) the diff since the plan was written, then replies `PASS` with a short assessment or `FIX:` with a numbered list. Route `FIX:` items back into `work` on the same ID, then critique again; report to the user once critique passes.

`status ID` reports plan progress (`plan=k/n`) once a plan exists, alongside the usual turn status.

## Herdr spawn

When `HERDR_ENV=1`, every child-starting launch (`start`, `follow-up`, `plan`, `work`, `critique`) uses this path. Load `using-herdr` for CLI mechanics. Keep persisted sessions and intercom on the helper.

1. Confirm `HERDR_ENV=1` and load `using-herdr`.

   This step is complete when that skill is loaded.

2. Read the current workspace and focused pane from live `workspace list` / `pane list`.

   This step is complete when those current ids are in hand.

3. Create an observable `subagents` tab in that workspace if needed, then a pane for this turn, both with `--no-focus`. Parse the new pane id from the create/split JSON.

   This step is complete when the new pane exists, is unfocused, and its id is stored.

4. `pane run` the helper command in that pane from the parent cwd, same flags as the non-Herdr path.

   This step is complete when the command is sent.

5. Capture `id`, `session`, `turn`, and paths from the pane output. Before a later read, wait, or launch, re-resolve the pane id from a fresh list or create response — Herdr ids compact.

   This step is complete when those values are captured and the pane id matches live Herdr state.

Tell the user workspace, tab, and pane on first Herdr success. Completed Herdr panes stay visible. Intercom remains the result channel.

## Watch window

When `HERDR_ENV=1`, the watch surface is the Herdr pane from Herdr spawn.

Otherwise invoke the helper from this supervisor. Tmux watch is selected only when `tmux` is on PATH and this supervisor is inside a live current tmux session. Then each subagent turn gets one watch pane in this session's helper-owned watch window named `subagents`, tiled. Otherwise the helper runs the turn headless and prints `watch=none reason=tmux-not-installed` or `watch=none reason=not-inside-tmux`. Watch attaches to the current supervisor session only.

On tmux success the helper prints `watch=tmux tmux_session=<name> window=subagents pane=<id>`. `tmux_session` is the tmux session name; `session=` is the jsonl path. Tell the user those three values on first tmux success. If tmux was selected and setup fails — including an unmarked or duplicate `subagents` window — the launch exits nonzero: no child, no headless retry.

The helper reuses only the helper-owned `subagents` window in this session. A new watch pane is established and retained before the child runs and before extra completed panes are swept, so a fast-finishing turn still leaves an observable pane. `list` and later launches keep the last completed pane as the window's anchor. Live panes stay. `stop` signals the child; its watch pane remains.

Each tmux watch pane runs the child as a real pi TUI. When the agent settles, a watch extension shuts pi down; the pane keeps the final conversation frame plus a recap of the last output lines, then shows the dead-pane banner. The result artifact is recovered from the session file after exit. Delegation still runs when watch is headless.

All tmux work is `scripts/pi-subagent-tmux.sh` (CLI subprocess). Core `pi-subagent.sh` selects tmux vs headless only on the non-Herdr path.

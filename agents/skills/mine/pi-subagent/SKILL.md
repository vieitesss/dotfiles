---
name: pi-subagent
description: Delegate tasks to independent child Pi processes with persisted sessions, including a plan/work/critique arc for multi-step work. Subagent sessions report completions and escalations back over pi-intercom, each running in its own tmux pane. Use when work should be handed to a subagent, independent work can run asynchronously, delegated work needs a follow-up, status check, wait, listing, or stop, or multi-step work needs a plan executed node-by-node and critiqued.
---

# Pi Subagent

Resolve `scripts/pi-subagent.sh` relative to this `SKILL.md` and invoke it from the parent Pi process's current working directory.

Subagent sessions talk back over `pi-intercom`. Each child gets a `contact_supervisor` tool bound to the parent session, sends a `TASK COMPLETE:` completion report when it finishes, and may escalate mid-task. Completion reports are the result channel; the file artifacts are crash forensics. Every launched subagent also runs in its own pane of a shared `subagents` tmux window — on first launch, tell the user the window name so they can watch.

## Delegate

1. Choose the task and execution mode.
   - Prefer `--async`: completion reports arrive inline via intercom, so the parent keeps doing independent work and consumes results as they land.
   - Use foreground mode only when the parent's very next step depends on the result.
   - Permit one editing subagent at a time in the active checkout; read-only tasks may overlap.
   - Express roles such as reviewer or planner in the task prompt. Each delegated task gets its own session ID.
   - Pass `--agent ROLE` with the profile row used below (`worker` otherwise).
   - Multi-step delegated work defaults to the arc below (`plan` -> `work` -> `critique`) instead of a single `start` call. Apply it without asking whenever there is more than one step.

   This step is complete when the mode is chosen and no editing subagent conflicts with an active one.

2. Write a self-contained prompt file. Include the task, relevant conversational context, constraints, expected output, and whether the child may edit. The child starts with fresh conversational context plus normal `AGENTS.md`/`CLAUDE.md` discovery.

   Match the task to a profile below and apply it without asking; anything else uses the default row.

   | Type | Purpose | Model | Effort |
   |---|---|---|---|
   | researcher | Web/docs research with sources: official docs, specs, benchmarks, recent changes, and a concise research brief. | `github-copilot/grok-4.6` | `xhigh` |
   | planner | A concrete implementation plan from existing context. Read and plan, not edit code. | `github-copilot/grok-4.6` | `xhigh` |
   | scout | Fast local codebase recon: relevant files, entry points, data flow, risks, and where another agent should start. | `github-copilot/gpt-5.6-luna` | `max` |
   | (default) | Anything not matching a type above. | `github-copilot/gpt-5.6-luna` | `max` |

   An explicit override must provide both `--model` and `--effort`; ask for the missing member of a partial override.

   Add explicitly requested skills with repeated `--skill PATH` options. Repeat them on each later turn that needs them.

   This step is complete when the prompt file alone contains everything the child needs.

3. Resolve your intercom presence name, then launch:

   ```typescript
   intercom({ action: "list" })   // read the "Current session" row
   ```

   ```sh
   "$helper" start [--async] [--orchestrator-target NAME] [--agent ROLE] \
       [--model MODEL --effort LEVEL] [--skill PATH] PROMPT_FILE
   ```

   - If your session is named, pass `--orchestrator-target NAME` with that name so completion reports and escalations route to you.
   - If it is unnamed (a `subagent-chat-...` alias), omit the flag; the helper derives the alias from the parent session.
   - The helper returns the session ID, the exact session, prompt, result, stderr, and exit-code paths, and the watch window name. The child launches with the parent session's `PI_SESSION_ID`/`PI_MODEL`/etc. bash-tool metadata stripped, plus bridge metadata that binds its `contact_supervisor` tool to you.

   This step is complete when those values are captured.

4. Consume results.
   - Completion reports arrive as inline intercom messages prefixed `TASK COMPLETE:` — treat the report (outcome, what changed or was found, key files, what remains) as the result.
   - `need_decision` escalations block the child with a 10-minute timeout: reply promptly with `intercom({ action: "reply", message: "..." })`. Answer `interview_request` escalations with the documented `{ "responses": [...] }` JSON. Read `UPDATE:` progress messages; no reply required.
   - An expected report that never arrives is the failure signal: run `wait`/`status ID`, then inspect the returned stderr path and `turn-NNN.result.partial.md`. A failed turn has no result artifact.
   - Foreground: check the command exit status first, then consume the report.

   This step is complete when dependent work uses a successful result, or failure diagnostics have been reported.

## Continue or control a session

```sh
# Continue the same conversation and model profile; reuses the supervisor target and watch window
"$helper" follow-up ID [--async] [--orchestrator-target NAME] [--agent ROLE] [--skill PATH] PROMPT_FILE

# Replace the persisted profile for this and later turns
"$helper" follow-up ID --model MODEL --effort LEVEL PROMPT_FILE

# Observe or control delegated work
"$helper" status ID
"$helper" wait ID
"$helper" list
"$helper" stop ID
```

`stop` sends a termination signal; the subagent's pane stays visible after death until swept (see Watch window). Use `wait` or `status` afterward to observe completion.

Sessions persist under `./.pi-subagent-runs/<id>/`. Remove an exact session directory only when the user explicitly requests deletion.

## Arc: plan -> work -> critique

Default to this arc for delegated work with more than one step. Skip it for a single trivial task (`start` directly) or pure research (the `researcher` profile, no plan).

The plan file is the arc's only state: `.pi-subagent-runs/<id>/plan.md`, a checklist of nodes with acceptance criteria. Which node is next and how much is done are always read from it, never tracked separately.

1. **Plan.** Write a prompt that tells the planner to produce a plan only — do not implement anything — then launch it. It explores read-only and writes the plan:

   ```sh
   "$helper" plan [--async] [--orchestrator-target NAME] [--skill PATH] PROMPT_FILE
   ```

   Uses the `planner` profile (`github-copilot/grok-4.6`/`xhigh`) unless overridden. The planner's session has no `edit`/`write` tools, so it cannot implement even if it tries. Read `plan.md` back and show it to the user; proceed once they approve it or ask for edits.

2. **Work.** Drive the worker one node at a time; each call implements the next unchecked node and ticks it off:

   ```sh
   "$helper" work ID [NODE...] [--async] [--model MODEL --effort LEVEL] [--agent ROLE]
   ```

   `NODE` words are an optional hint (e.g. a node number) when a specific node should go next instead of the default "next unchecked". Defaults to the ordinary worker profile and agent label (`github-copilot/gpt-5.6-luna`/`max`, `worker`) regardless of what the planner used, so the commodity model carries execution and pane titles/reports reflect the current stage; pass `--model`/`--effort`/`--agent` to use something else for that turn. The worker may take a following node in the same turn only when it is trivially small and strictly sequential — otherwise one node per call. Repeat until `status ID` reports every node checked (`plan=k/n`). A `need_decision` escalation mid-node behaves like any other subagent escalation: reply, then call `work` again to resume.

3. **Critique.** Launch a fresh, read-only child that judges the plan against what was actually done:

   ```sh
   "$helper" critique ID [--async] [--orchestrator-target NAME] [--model MODEL --effort LEVEL]
   ```

   Uses the frontier `github-copilot/grok-4.6`/`xhigh` profile by default — a critic is worth the same weight as a planner. Like the planner, its session has no `edit`/`write` tools. It reads `plan.md`, the worker's artifacts, and (inside a Git repo) the diff since the plan was written, then replies `PASS` with a short assessment or `FIX:` with a numbered list. Route `FIX:` items back into `work` on the same ID; report to the user once critique passes.

`status ID` reports plan progress (`plan=k/n`) once a plan exists, alongside the usual turn status.

## Watch window

The helper creates a tmux window named `subagents` in the current tmux session and runs each subagent turn in its own pane with a tiled layout. Each pane runs the child as a real pi TUI, so you can watch the subagent work live — streaming output, tool calls, and its status line. When the agent settles, a watch extension shuts pi down gracefully; the pane keeps the final conversation frame plus a recap of the last output lines, then shows the dead-pane banner. No manual cleanup is needed: the next subagent launch, or the next `list` call, sweeps every dead pane in the window first (tmux itself removes the window once its last pane is gone). The result artifact is recovered from the session file after exit.

Watch windows are scoped to the current tmux session — stale `subagents` windows in other sessions are never reused. Outside tmux, the helper uses a dedicated `subagents` tmux session instead. The launch output names the session and pane, and the helper prints `watching in tmux session ...` so the window is easy to find. If tmux is not installed or no server is running, the helper prints a notice and runs children headless (single-shot print mode) — nothing about delegation depends on tmux.

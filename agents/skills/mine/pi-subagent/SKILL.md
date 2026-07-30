---
name: pi-subagent
description: Delegate tasks to independent child Pi processes with persisted sessions. Use when work should be handed to a subagent, independent work can run asynchronously, or delegated work needs a follow-up, status check, wait, listing, or stop.
---

# Pi Subagent

Resolve `scripts/pi-subagent.sh` relative to this `SKILL.md` and invoke it from the parent Pi process's current working directory.

## Delegate

1. Choose the task and execution mode.
   - Use foreground mode when the parent's next step depends on the result.
   - Add `--async` when the parent has independent work to continue.
   - Permit one editing subagent at a time in the active checkout; read-only tasks may overlap.
   - Express roles such as reviewer or planner in the task prompt. Each delegated task gets its own session ID.

   This step is complete when the mode is chosen and no editing subagent conflicts with an active one.

2. Write a self-contained prompt file. Include the task, relevant conversational context, constraints, expected output, and whether the child may edit. The child starts with fresh conversational context plus normal `AGENTS.md`/`CLAUDE.md` discovery.

   Match the task to a profile below and apply it without asking; anything else uses the default row.

   | Type | Purpose | Model | Effort |
   |---|---|---|---|
   | researcher | Web/docs research with sources: official docs, specs, benchmarks, recent changes, and a concise research brief. | `github-copilot/claude-sonnet-5` | `high` |
   | planner | A concrete implementation plan from existing context. Read and plan, not edit code. | `github-copilot/claude-sonnet-5` | `high` |
   | scout | Fast local codebase recon: relevant files, entry points, data flow, risks, and where another agent should start. | `openai-codex/gpt-5.6-luna` | `max` |
   | (default) | Anything not matching a type above. | `openai-codex/gpt-5.6-luna` | `max` |

   Scout is two-tier: try `openai-codex/gpt-5.6-luna`/`max` first; if that `start` invocation fails (non-zero exit, no session produced), retry once with `github-copilot/claude-sonnet-5`/`high`.

   An explicit override must provide both `--model` and `--effort`; ask for the missing member of a partial override.

   Add explicitly requested skills with repeated `--skill PATH` options. Repeat them on each later turn that needs them.

   This step is complete when the prompt file alone contains everything the child needs.

3. Launch the child and retain every returned path:

   ```sh
   "$helper" start [--async] [--model MODEL --effort LEVEL] [--skill PATH] PROMPT_FILE
   ```

   The helper returns the session ID and exact session, prompt, result, stderr, and exit-code paths. The child launches with the parent session's `PI_SESSION_ID`/`PI_MODEL`/etc. bash-tool metadata stripped, so it never inherits stale state from the parent. This step is complete when those values are captured.

4. Consume the result artifact only after successful completion.
   - Foreground: check the command exit status, then read the returned result path.
   - Asynchronous: continue independent work, then run `wait` before any dependent work.
   - On failure, inspect the returned stderr path and `turn-NNN.result.partial.md`; a failed turn has no result artifact.

   This step is complete when dependent work uses a successful result, or failure diagnostics have been reported.

## Continue or control a session

```sh
# Continue the same conversation and model profile
"$helper" follow-up ID [--async] [--skill PATH] PROMPT_FILE

# Replace the persisted profile for this and later turns
"$helper" follow-up ID --model MODEL --effort LEVEL PROMPT_FILE

# Observe or control delegated work
"$helper" status ID
"$helper" wait ID
"$helper" list
"$helper" stop ID
```

`stop` sends a termination signal; use `wait` or `status` afterward to observe completion.

Sessions persist under `./.pi-subagent-runs/<id>/`. Remove an exact session directory only when the user explicitly requests deletion.

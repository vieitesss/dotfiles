# Paseo extension

Pick this file when `PASEO_AGENT_ID` is set: you are a Paseo agent, and the
Subagent becomes a native Paseo agent whose caller is you. Pass its absolute
path as `--extension`; the Subagent is told to read it to report.

## Manager: launching a Stage

Prepare the Stage as in [`SKILL.md`](../SKILL.md) with
`--extension "$SKILL/extensions/paseo.md" --manager "$PASEO_AGENT_ID"`, then
start the session from the spec:

```bash
printf '%s\n' "$spec" | python3 "$SKILL/extensions/paseo/host.py" launch [WORKSPACE]
```

`launch` prints `{"host":"paseo","agentId":"...","name":"subagent-..."}`.
Record `agentId` in the Ledger, end your turn, and wait for the Subagent's
message.

- **Placement.** An agent-scoped `paseo run` defaults to the caller's
  workspace, so `--cwd` alone is honored only for your own directory. The
  helper therefore picks: the workspace id you pass, else yours when `--cwd` is
  your directory, else a workspace already rooted at `--cwd`, else a new
  local workspace for it (it points at an existing directory and creates no
  worktree). An explicit workspace id is refused unless the daemon lists it and
  its root is `--cwd`, because the CLI otherwise substitutes that root for the
  prepared directory. Each Stage runs where `--cwd` says, never in a new
  worktree, and no UI focus changes. If a successful run still reports another
  directory, the helper archives that agent and refuses instead of letting it
  edit there.
- **Role.** `paseo run` has no system-prompt flag, so the helper sends the
  spec's `prompt` as the first message; the Stage role leads it.
- **Engine.** A `claude-code/<alias>` model runs `--provider claude --model
  <alias>`, and Paseo resolves the alias; any other model runs `--provider pi
  --model <provider/model>`. The effort is the spec's already-clamped engine
  value, passed as `--thinking`.
- **Permissions.** Claude roles run `--mode auto`: Paseo keeps its permission
  checks and reviews tool calls instead of asking, so the Subagent can usually
  send its report unattended. Auto can still hold a request, and Paseo does not
  push a CLI-created agent's request to you, so it waits for the user. Never
  launch with `bypassPermissions`, and never approve in bulk
  (`permit --all`).

If the user says a Stage looks stuck, run `"$PASEO_CLI" permit ls` and show
them any pending request. Approving or denying is theirs to say; answer only
the request they name with `permit allow AGENT_ID REQ_ID` or
`permit deny AGENT_ID REQ_ID`.

A failed `launch` exits non-zero with the CLI's error, clipped to 2000
characters. Clipping limits length only; it is not redaction, so treat the
message as possibly echoing part of the brief. A failure before the run prints
no `agentId`, so there is nothing to record: run `"$PASEO_CLI" ls` once for the
spec's `name` before retrying, and archive any agent a failed attempt left
behind. A run that succeeds in another directory is different: the helper
force-archives that known agent id (history kept, as in close below) before
refusing, and if the CLI refuses the archive the message keeps the id so you can
archive or stop it yourself.

## Manager: follow-up and close

```bash
# answer a Question, or send a follow-up after a report
python3 "$SKILL/extensions/paseo/host.py" send AGENT_ID "MESSAGE"

# once the report is accepted
python3 "$SKILL/extensions/paseo/host.py" archive AGENT_ID
```

`send` never blocks, and long or multi-line text arrives whole. `archive` ends
the session and keeps its history; it forces the CLI so an accepted Subagent
whose reporting turn is still running is interrupted instead of refusing to
close.

## Subagent: reporting

Your prompt names the Manager's address. Reach it with the Paseo CLI the
session already exports:

```bash
"$PASEO_CLI" send --no-wait MANAGER "[TAG] TASK COMPLETE: <one line>; report: <report path>"
"$PASEO_CLI" send --no-wait MANAGER "[TAG] QUESTION: <question>"
```

Both are fire-and-forget. After a QUESTION, end your turn; the Manager's
answer arrives as your next prompt. Do not use intercom, do not poll, and do
not read other agents or the Manager's queue.

# Paseo extension

Pick this host when the Manager's conversation runs in Paseo. On the Manager's
own machine, `PASEO_AGENT_ID` identifies it; a remote shell may have no Paseo
variables. A same-daemon Subagent becomes a native Paseo agent whose caller
is you. Pass this file's absolute path as `--extension` for same-daemon
sessions; across machines, use [paseo-remote.md](paseo-remote.md).

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

- **Placement.** `paseo run` defaults to the caller's workspace, so the helper
  chooses: the explicit workspace, the caller's when `--cwd` matches, an
  existing workspace rooted at `--cwd`, or a new local workspace in the
  caller's project (a project of its own only if the daemon cannot identify
  yours). It creates no worktree or focus change. The helper rejects an
  explicit workspace not listed at `--cwd`, and archives and refuses an agent
  that still lands in another directory.
- **Engine.** Paseo receives the spec's prompt as its first message (there is
  no system-prompt flag). `claude-code/<alias>` uses `--provider claude`;
  other models use `--provider pi`. The spec's clamped effort is `--thinking`.
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

## Manager: close

Once the report is accepted, close the Subagent, keeping its history:

```bash
python3 "$SKILL/extensions/paseo/host.py" archive AGENT_ID
```

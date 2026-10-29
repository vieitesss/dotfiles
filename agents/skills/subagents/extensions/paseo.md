# Paseo extension

Pick this host when the Manager's conversation runs in Paseo. On the Manager's
own machine, `PASEO_AGENT_ID` identifies it; a remote shell may have no Paseo
variables. A same-daemon Subagent becomes a native Paseo agent whose caller
is you. Pass this file's absolute path as `--extension` for same-daemon
sessions; across machines, prepare the return route below instead.

## Remote sessions

Launch, follow-up and close target the Subagent's daemon; reports target the
Manager's daemon. Identify where each agent actually runs: a Mac Paseo UI
connected to an RPi daemon is still the same-daemon case. An agent id alone
does not choose a daemon; `PASEO_CLI` names an executable, not a destination.
The example below has a Mac Manager and an RPi Subagent.

Before launching:

1. Obtain the Manager's **Paseo agent id from the Mac session**, and the
   credential-free daemon endpoints (or configured wrappers) for both routes.
   An RPi `TMUX_PANE` and a Claude transcript UUID identify neither the Mac
   Manager nor its daemon. Ask the user for any missing route; keep credentials
   in the machine's existing configuration, out of prompts and command arguments.
2. On the RPi, write a per-session Markdown extension with the Manager's id,
   its machine, and a concrete reporting command usable from the RPi. Point at
   this file for the other Paseo mechanics. For example, substitute real values
   in this file before using it as `--extension`:

   ```markdown
   # Remote Paseo session
   Read /RPi/path/to/subagents/extensions/paseo.md for Paseo mechanics.
   Manager: MAC_AGENT_ID on the Mac, daemon MAC_ENDPOINT.
   Reporting from the RPi uses this explicit route, not the local daemon:
   paseo --host MAC_ENDPOINT send --no-wait MAC_AGENT_ID "[TAG] TASK COMPLETE: <one line>; report: <RPi report path>"
   paseo --host MAC_ENDPOINT send --no-wait MAC_AGENT_ID "[TAG] QUESTION: <question>"
   After reporting or asking, end your turn; follow-ups arrive here.
   ```

   Use an installed CLI path or SSH wrapper if needed. This explicit route
   replaces the same-daemon reporting commands below.
3. Prepare on the RPi with `--extension /RPi/path/to/remote-paseo.md` and
   `--manager MAC_AGENT_ID`, then launch against the RPi daemon. The helper
   rejects a missing Manager or a tmux pane such as `%36` before any call;
   caller inheritance does not establish a return route to the Mac.
4. Keep the returned RPi `agentId` **with its daemon endpoint** in the Ledger.
   From the Mac, follow up and close against the RPi daemon:

   ```bash
   paseo --host RPI_ENDPOINT send --no-wait RPI_AGENT_ID "MESSAGE"
   paseo --host RPI_ENDPOINT archive --force RPI_AGENT_ID
   ```

   Read reports from their RPi paths over the existing remote connection.

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

## Manager: follow-up and close

```bash
# answer a Question, or send a follow-up after a report
python3 "$SKILL/extensions/paseo/host.py" send AGENT_ID "MESSAGE"

# once the report is accepted
python3 "$SKILL/extensions/paseo/host.py" archive AGENT_ID
```

`send` queues whole messages until the receiver is idle, one per turn; an
immediate send would interrupt a running tool call. Its output names a log
ending in DELIVERED or FAILED. `archive` force-closes the session, interrupting
any running turn while keeping history.

When a TASK COMPLETE never arrives, `pending` lists idle `subagent-*` agents
with their delivery state, undelivered first:

```bash
python3 "$SKILL/extensions/paseo/host.py" pending
```

An idle Subagent with no DELIVERED record either never reported or lost the
message: read its report from the Ledger path and follow up with `send`.

## Subagent: reporting

Use the extension path in your prompt, not the local environment, to choose
the route. For `extensions/paseo.md`, the prompt names the same-daemon Manager;
the helper uses `$PASEO_CLI` or `paseo` on PATH. No `--host` is needed:

```bash
python3 EXTENSIONS_DIR/paseo/host.py send MANAGER "[TAG] TASK COMPLETE: <one line>; report: <report path>"
python3 EXTENSIONS_DIR/paseo/host.py send MANAGER "[TAG] QUESTION: <question>"
```

For a remote Manager, use the explicit command in your per-session extension;
the local default daemon is not the Mac's. Run the exact commands in your
prompt: the helper validates the id before queueing and names the delivery log.

# Paseo extension

Pick this host when the Manager's conversation runs in Paseo. On the Manager's
own machine, `PASEO_AGENT_ID` identifies it; a remote shell may have no Paseo
variables. A same-daemon Subagent becomes a native Paseo agent whose caller
is you. Pass this file's absolute path as `--extension` for same-daemon
sessions; across machines, prepare the return route below instead.

## Remote sessions

A Paseo Manager on a Mac can launch a Subagent on an RPi. There are two
routes: the Subagent's daemon for launch, follow-up and close, and the
Manager's daemon for reports. Identify the daemon actually hosting each
agent: a Mac Paseo UI connected to an RPi daemon is still the same-daemon
case. An agent id alone does not choose a daemon, and `PASEO_CLI` names an
executable, not a remote destination. The example below has a Mac-hosted
Manager and an RPi-hosted Subagent.

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

   Use an installed CLI path or an existing SSH wrapper if `paseo` is not on
   the RPi's PATH. The explicit remote route in this file replaces the
   same-daemon reporting commands below.
3. Prepare on the RPi with `--extension /RPi/path/to/remote-paseo.md` and
   `--manager MAC_AGENT_ID`, then run the launch helper there against the RPi
   daemon. Preparation resolves all paths on the RPi. The helper refuses a
   missing Manager address or a tmux pane address such as `%36` before any
   daemon call. Same-daemon caller inheritance does not establish a return
   route to the Mac.
4. Keep the returned RPi `agentId` **with its daemon endpoint** in the Ledger.
   From the Mac, follow up and close against the RPi daemon:

   ```bash
   paseo --host RPI_ENDPOINT send --no-wait RPI_AGENT_ID "MESSAGE"
   paseo --host RPI_ENDPOINT archive --force RPI_AGENT_ID
   ```

   Read reports from their RPi paths over the existing remote connection.

The Subagent checks the supplied route before Stage work. Missing executables,
unspecified daemon destinations or a conflicting host earn a Question in the
launching conversation; it never discovers a replacement Manager among local
panes or agents.

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

Your prompt names the Manager's address. For a same-daemon session, reach it
with the helper next to this file (`paseo/host.py` in the directory that holds
it); the helper uses `$PASEO_CLI` when set, otherwise `paseo` on PATH:

```bash
python3 EXTENSIONS_DIR/paseo/host.py send MANAGER "[TAG] TASK COMPLETE: <one line>; report: <report path>"
python3 EXTENSIONS_DIR/paseo/host.py send MANAGER "[TAG] QUESTION: <question>"
```

For a remote Manager, use the explicit reporting command in your per-session
extension instead. A local CLI's default daemon is not the Mac's daemon.

Both are fire-and-forget. After a QUESTION, end your turn; the Manager's
answer arrives as your next prompt. Do not use intercom, do not poll, and do
not read other agents or the Manager's queue.

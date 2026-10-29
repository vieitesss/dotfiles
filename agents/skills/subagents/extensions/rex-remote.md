# Rex remote extension

Pick this file when the Manager runs in Rex (`REX_SESSION` is set) and the
Stage runs over SSH on a machine without Rex. The Subagent runs in tmux there;
recado machines carry messages in both directions. Pass this file's absolute
path **on the remote machine** as `--extension`.

## Setup

On both machines install recado and make it available on PATH to SSH and the
agent's login shell. `update` installs the latest binary and harness shims:

```bash
recado update
ssh MACHINE 'recado update'
recado machine add MACHINE ssh MACHINE
```

Register each remote machine once on the Manager's machine; SSH must log in
without prompting. Setup installs the hooks that register the Subagent at
session start. The Manager also needs a recado identity: restart its session
if setup was just installed.

## Manager: launching a Stage

Prepare on the remote machine, so `--cwd`, skill paths and the report path are
readable there. Keep your Rex block as `--manager`. Build `--manager-recado`
from **your** local recado identity and hostname, not `recado whoami` on the
remote machine. Copy the brief over first, so the remote shell never parses it:

```bash
SKILL=~/.agents/skills/subagents
manager=$(recado whoami)
case "$manager" in recado://local/*) ;; *) echo 'Manager recado identity unavailable' >&2; exit 1 ;; esac
upstream="recado+upstream://$(hostname)/${manager#recado://local/}"
ssh MACHINE 'cat > /tmp/brief-ITEM.md' < BRIEF_FILE
spec=$(ssh MACHINE "S=~/.agents/skills/subagents
  trap 'rm -f /tmp/brief-ITEM.md' 0
  python3 \"\$S/scripts/subagent.py\" --stage STAGE --item ITEM --cwd REMOTE_DIR \\
    --extension \"\$S/extensions/rex-remote.md\" --manager '$REX_BLOCK' \\
    --manager-recado '$upstream' \"\$(cat /tmp/brief-ITEM.md)\"") || exit 1
printf '%s\n' "$spec" | python3 "$SKILL/extensions/rex/host.py" remote-launch MACHINE [SESSION]
```

`remote-launch` validates the Manager block, launches tmux, and sends a
kickoff to `recado://MACHINE/<spec name>` to start recado's return relay. The
kickoff is not a follow-up. It prints
`{"host":"tmux","machine":"MACHINE","session":"...","window":"@N","pane":"%N","name":"...","kickoff":"<message id>"}`.
Record the machine, name, window, pane and kickoff id in the Ledger.

- `SESSION` names a tmux session on the remote machine. By default the window
  goes to a detached `subagents` session, created when missing; attach with
  `ssh -t MACHINE tmux attach -t subagents`.
- If kickoff fails, the error includes the already-created session ids. Fix
  the reported problem (including a missing remote registration), then send
  `recado send recado://MACHINE/NAME 'Continue the brief; this opens the recado return route.'`
  or close the window; do not launch a duplicate Stage.
- The report path is on the remote machine. Read it there over SSH when it is
  not in a shared checkout.

## Manager: follow-up and close

Answer a Question with `recado reply MESSAGE_ID "ANSWER"`. For later follow-ups
and close:

```bash
recado send recado://MACHINE/NAME "MESSAGE"
python3 "$SKILL/extensions/rex/host.py" remote-close MACHINE WINDOW
```

## Subagent: reporting

Use the exact `recado send` and `recado ask` commands in the prepared prompt.
After a Question or Completion report, end your turn and wait.

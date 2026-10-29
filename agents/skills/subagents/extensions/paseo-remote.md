# Paseo remote extension

Pick this file when the Manager runs in Paseo and the Stage runs on another
machine and daemon. Read [paseo.md](paseo.md) for launch and close mechanics.
Pass this file's absolute path on the Stage machine as `--extension`.

## Setup

Install recado on both machines and make it available on PATH to SSH and the
agent's login shell. Run `recado update` on each machine, then register the
Stage machine on the Manager's machine with `recado machine add MACHINE ssh
MACHINE`. SSH must log in without prompting. Restart the Manager session after
installing its recado hooks. The remote Paseo CLI must reach the Stage's daemon;
configure it there or set `PASEO_CLI` to an executable wrapper for that endpoint.
Keep daemon credentials in the machine's existing configuration.

## Manager: launch and close

Prepare on the Stage machine. Take the Manager's Paseo id and recado identity
from the Manager session, not from the remote shell. Copy the brief over first:

```bash
SKILL=~/.agents/skills/subagents
manager=$(recado whoami)
case "$manager" in recado://local/*) ;; *) echo 'Manager recado identity unavailable; restart the Manager' >&2; exit 1 ;; esac
upstream="recado+upstream://$(hostname)/${manager#recado://local/}"
ssh MACHINE 'cat > /tmp/brief-ITEM.md' < BRIEF_FILE
spec=$(ssh MACHINE "S=~/.agents/skills/subagents
  trap 'rm -f /tmp/brief-ITEM.md' 0
  python3 \"\$S/scripts/subagent.py\" --stage STAGE --item ITEM --cwd REMOTE_DIR \\
    --extension \"\$S/extensions/paseo-remote.md\" --manager '$PASEO_AGENT_ID' \\
    --manager-recado '$upstream' \"\$(cat /tmp/brief-ITEM.md)\"") || exit 1
result=$(printf '%s\n' "$spec" | ssh MACHINE 'python3 ~/.agents/skills/subagents/extensions/paseo/host.py launch [WORKSPACE]') || exit 1
```

Record the remote machine, daemon, `agentId` and `name` from `result` in the
Ledger. Send a kickoff from the Manager to `recado://MACHINE/NAME` with
`recado send recado://MACHINE/NAME 'Continue the brief; this opens the recado return route.'`.
It opens the return relay and is not a follow-up. If it fails, fix the setup and
send it again or close the existing session; do not launch a duplicate. Read the
report from its remote path over SSH when it is not in a shared checkout.

Once the report is accepted, close on the same daemon used for launch:

```bash
ssh MACHINE 'python3 ~/.agents/skills/subagents/extensions/paseo/host.py archive AGENT_ID'
```

#!/usr/bin/env python3
"""Launch mechanics shared by the interactive host extensions (tmux, herdr).

Core prepares a host-independent spec; the interactive helpers are the only
hosts that need Claude Code's workspace-trust dialog pre-accepted and an effort
retry when a pane shows the chosen level was rejected, and a check that the
Manager address is the pane the Manager runs in. This module owns those
pieces, so the behaviour has one definition instead of a copy per host. It
is extension-owned, not core: a host that does not need it does not import it.
"""

import json
import os
import subprocess
import sys


def without_effort(argv, kind, view):
    """argv minus the effort flag if the pane shows the level made it fail, else None.

    Only error lines count; a pane echoes the command line, which always
    contains "thinking".
    """
    errors = [line.lower() for line in view.splitlines() if "error" in line.lower()]
    level_error = any(
        any(w in line for w in ("thinking", "reasoning", "effort")) for line in errors
    )
    effort_flag = "--effort" if kind == "claude" else "--thinking"
    if effort_flag not in argv or not level_error:
        return None
    cut = argv.index(effort_flag)
    return [arg for i, arg in enumerate(argv) if i not in (cut, cut + 1)]


def trust_claude_dir(cwd):
    """Pre-accept Claude Code's workspace trust dialog for cwd.

    Interactive claude has no flag to skip the dialog; it reads
    projects[<path>].hasTrustDialogAccepted from ~/.claude.json. This marks
    workspace trust only: it is not a permission bypass, and Claude Code's own
    permission checks stay in place.
    """
    path = os.path.expanduser("~/.claude.json")
    try:
        with open(path, encoding="utf-8") as handle:
            config = json.load(handle)
    except FileNotFoundError:
        config = {}
    except (OSError, ValueError) as err:
        print(f"[subagent] cannot read {path} ({err}); skipping trust", file=sys.stderr)
        return
    project = config.setdefault("projects", {}).setdefault(os.path.realpath(cwd), {})
    if project.get("hasTrustDialogAccepted"):
        return
    project["hasTrustDialogAccepted"] = True
    tmp = f"{path}.subagent-{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=2)
    os.replace(tmp, path)


def manager_pane_error(pane, shell_pid):
    """Why pane, whose shell runs as shell_pid, cannot be this Manager's address.

    None when it is. Reports are typed into the Manager's pane and submitted,
    so a pane that is not the Manager's (a Paseo agent inherits the pane
    variables of whatever pane started its daemon) would get every report
    typed into whatever runs there.
    """
    if os.environ.get("PASEO_AGENT_ID"):
        return (
            "the Manager is a Paseo agent with no pane of its own; "
            f"use {os.path.join(os.path.dirname(os.path.abspath(__file__)), 'paseo.md')} "
            "and --manager \"$PASEO_AGENT_ID\" instead"
        )
    if not str(shell_pid).isdigit():
        return f"--manager {pane} is not a pane"
    if int(shell_pid) not in ancestors(os.getpid()):
        return f"--manager {pane} is not the pane this Manager runs in"
    return None


def ancestors(pid):
    """pid and every parent process up to init."""
    seen = []
    while pid > 1 and pid not in seen:
        seen.append(pid)
        out = subprocess.run(
            ["ps", "-o", "ppid=", "-p", str(pid)],
            capture_output=True, text=True, check=False,
        ).stdout.strip()
        if not out.isdigit():
            break
        pid = int(out)
    return seen

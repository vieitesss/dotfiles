#!/usr/bin/env python3
"""Launch mechanics shared by the interactive host extensions (tmux, herdr).

Core prepares a host-independent spec; the interactive helpers are the only
hosts that need Claude Code's workspace-trust dialog pre-accepted and an effort
retry when a pane shows the chosen level was rejected. This module owns those
two pieces, so the behaviour has one definition instead of a copy per host. It
is extension-owned, not core: a host that does not need it does not import it.
"""

import json
import os
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

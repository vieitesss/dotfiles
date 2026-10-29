#!/usr/bin/env python3
"""Launch and safety mechanics shared by the host extensions."""

import json
import os
import shlex
import subprocess
import sys
import tempfile

# Allow slow login shells (including 35s startup) without retaining orphaned
# secret env files indefinitely. Only the env file is age-swept, never the task.
TEMP_FILE_SWEEP = 120
# Parent variables a child inherits even though the host spawns it from its
# server's environment; the child sources them from a 0600 temp file.
PASSTHROUGH_ENV = ["TYPESAFE_API_KEY"]

# A login shell is not enough for the environment (zsh reads ~/.zprofile, not
# ~/.profile), so the child sources the allowlisted env file and deletes it
# before exec. The task travels through a second temp file because hosts reject
# over-long commands; that file is never age-swept.
CHILD_SCRIPT = (
    'if ! prompt=$(cat "$1"); then '
    'printf "%s\\n" "[subagent] cannot read prompt file: $1" >&2; '
    'rm -f "$1" "$2"; exit 1; fi; '
    'rm -f "$1"; if [ -r "$2" ]; then . "$2"; fi; rm -f "$2"; '
    'export RECADO_ADDR="$0"; '
    'if [ -n "$3" ]; then PATH="$3:$PATH"; export PATH; fi; '
    'shift 3; exec "$@" "$prompt"'
)


def child_command(name, prompt, kind, argv, recado_bin_dir=None):
    """argv that runs the engine with prompt as its last argument, and its temp files.

    The prompt file and the 0600 env file are deleted by the child; on a
    failed spawn the caller removes both with remove_temp.
    """
    path = env_path = None
    try:
        fd, path = tempfile.mkstemp(prefix=f"{name}-", suffix=".md")
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(prompt)
        fd, env_path = tempfile.mkstemp(prefix="subagent-env-")
        try:
            handle = os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape")
        except BaseException:
            os.close(fd)
            raise
        with handle:
            for var in PASSTHROUGH_ENV:
                value = os.environ.get(var)
                if value is not None:
                    handle.write(f"export {var}={shlex.quote(value)}\n")
        subprocess.Popen(
            ["/bin/sh", "-c", 'sleep "$1"; rm -f "$2"', "_", str(TEMP_FILE_SWEEP), env_path],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except BaseException:
        remove_temp(path, env_path)
        raise
    shell = os.environ.get("SHELL", "/bin/sh")
    command = [shell, "-lc", CHILD_SCRIPT, name, path, env_path, recado_bin_dir or "", kind, *argv, "--"]
    return command, (path, env_path)


def clip(text, limit=2000):
    """Limit failure detail length, without claiming to redact it."""
    text = (text or "").strip()
    return text if len(text) <= limit else f"{text[:limit]}…"


def identity_env(spec):
    """CLI environment flags for hosts that start the agent themselves."""
    flags = ["--env", f"RECADO_ADDR={spec['name']}"]
    if spec.get("recado_bin_dir"):
        flags += ["--env", f"PATH={spec['recado_bin_dir']}:{os.environ.get('PATH', '')}"]
    return flags


def engine_argv(spec, *notify_commands):
    """Engine flags and narrow Claude permissions for reporting and the report file."""
    argv = list(spec["engine"]["argv"])
    if spec["engine"]["kind"] == "claude":
        permissions = [f"Bash({command} *)" for command in notify_commands]
        permissions.append(f"Edit(/{spec['report']})")
        directory = spec.get("recado_bin_dir")
        if directory:
            for binary in ("recado", os.path.join(directory, "recado")):
                permissions += [f"Bash({binary} {action} *)" for action in ("send", "ask")]
        argv += ["--allowedTools", *permissions]
    return argv


def remove_temp(*paths):
    for path in paths:
        if not path:
            continue
        try:
            os.unlink(path)
        except OSError:
            pass


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

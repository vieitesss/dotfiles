#!/usr/bin/env python3
"""Host extension: launch and address a Stage Subagent in a tmux window.

Reads the launch spec printed by scripts/subagent.py on stdin.

Usage:
    host.py launch [SESSION]        # spec on stdin, prints {"window", "pane", ...}
    host.py notify PANE MESSAGE     # type a message into the Manager's pane
    host.py close WINDOW            # kill the Subagent's window

SESSION defaults to the calling agent's tmux session, taken from TMUX_PANE,
never whichever session is attached.
"""

import json
import os
import shlex
import subprocess
import sys
import tempfile
import time

# Launch mechanics shared with the other interactive host extensions.
EXTENSIONS_DIR = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
)
sys.path.insert(0, EXTENSIONS_DIR)
import host_launch  # noqa: E402

HOST = os.path.abspath(__file__)
STARTUP_GRACE = 3  # seconds a tmux child must survive to count as launched
# Allow slow login shells (including 35s startup) without retaining orphaned
# secret env files indefinitely. Only the env file is age-swept, never the task.
TEMP_FILE_SWEEP = 120
# Parent variables a child inherits even though tmux spawns it from the
# server's environment; the child sources them from a 0600 temp file.
PASSTHROUGH_ENV = ["TYPESAFE_API_KEY"]

# A login shell is not enough for the environment (zsh reads ~/.zprofile, not
# ~/.profile), so the child sources the allowlisted env file and deletes it
# before exec. The task travels through a second temp file because tmux rejects
# over-long commands; that file is never age-swept.
CHILD_SCRIPT = (
    'if ! prompt=$(cat "$1"); then '
    'printf "%s\\n" "[subagent] cannot read prompt file: $1" >&2; '
    'rm -f "$1" "$2"; exit 1; fi; '
    'rm -f "$1"; if [ -r "$2" ]; then . "$2"; fi; rm -f "$2"; '
    'shift 2; exec "$@" "$prompt"'
)


def clip(text, limit=2000):
    """A failure detail capped at limit characters; a length limit, not redaction."""
    text = (text or "").strip()
    return text if len(text) <= limit else f"{text[:limit]}…"


def tmux(*args, check=True, input=None):
    proc = subprocess.run(
        ["tmux", *args], capture_output=True, text=True, check=False, input=input
    )
    if check and proc.returncode != 0:
        sys.exit(f"tmux {args[0]} failed: {clip(proc.stderr or proc.stdout)}")
    return proc.stdout.strip()


def tmux_session():
    """tmux session of the calling agent's pane, not whichever one is attached."""
    pane = os.environ.get("TMUX_PANE")
    return tmux("display-message", "-p", *(["-t", pane] if pane else []), "#{session_id}")


def notify(pane, message):
    """Type message into pane and submit it.

    A bracketed paste keeps multi-line messages from submitting line by line.
    """
    buffer = f"subagent-{os.getpid()}"
    tmux("load-buffer", "-b", buffer, "-", input=message)
    tmux("paste-buffer", "-p", "-d", "-b", buffer, "-t", pane)
    time.sleep(0.3)  # let the TUI finish the paste before Enter submits it
    tmux("send-keys", "-t", pane, "Enter")


def claude_extra(spec):
    """Claude Code flags that let the Subagent report and edit its report."""
    notify_cmd = f"python3 {HOST} notify"
    return [
        "--allowedTools",
        f"Bash({notify_cmd} *)",
        f"Bash({sys.executable} {HOST} notify *)",
        f"Edit(/{spec['report']})",
    ]


def child_env_file(path):
    """0600 temp file exporting allowlisted parent variables for the child."""
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        handle = os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape")
    except BaseException:
        os.close(fd)
        remove_temp(path)
        raise
    try:
        with handle:
            for var in PASSTHROUGH_ENV:
                value = os.environ.get(var)
                if value is not None:
                    handle.write(f"export {var}={shlex.quote(value)}\n")
    except BaseException:
        remove_temp(path)
        raise
    return path


def remove_temp(*paths):
    for path in paths:
        try:
            os.unlink(path)
        except OSError:
            pass


def engine_argv(spec):
    argv = list(spec["engine"]["argv"])
    if spec["engine"]["kind"] == "claude":
        argv += claude_extra(spec)
    return argv


def launch_tmux(name, pane_id, argv, prompt, cwd, kind="pi"):
    """Start the agent in the tmux pane with the task as its first message.

    The pane remains after the agent exits, so a failed launch stays visible.
    """
    tmux("set-option", "-w", "-t", pane_id, "remain-on-exit", "on")
    shell = os.environ.get("SHELL", "/bin/sh")

    def start(extra):
        path = env_path = None
        env_created = False
        try:
            fd, path = tempfile.mkstemp(prefix=f"{name}-", suffix=".md")
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(prompt)
            env_path = os.path.join(
                tempfile.gettempdir(),
                f"subagent-env-{os.getpid()}-{os.urandom(8).hex()}",
            )
            subprocess.Popen(
                [
                    "/bin/sh", "-c", 'sleep "$1"; rm -f "$2"',
                    "_", str(TEMP_FILE_SWEEP), env_path,
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            child_env_file(env_path)
            env_created = True
            tmux(
                "respawn-pane", "-k", "-t", pane_id, "-c", cwd, "--",
                shell, "-lc", CHILD_SCRIPT, name, path, env_path, kind, *extra, "--",
            )
        except BaseException:
            remove_temp(path)
            if env_created:
                remove_temp(env_path)
            raise

        deadline = time.monotonic() + STARTUP_GRACE
        while time.monotonic() < deadline:
            pane_state = subprocess.run(
                ["tmux", "display-message", "-p", "-t", pane_id,
                 "#{pane_id} #{pane_dead}"],
                capture_output=True, text=True, check=False,
            )
            if pane_state.returncode != 0 or pane_state.stdout.strip() != f"{pane_id} 0":
                remove_temp(path, env_path)
                return False
            time.sleep(0.25)
        return True

    if start(argv):
        return True
    view = tmux("capture-pane", "-p", "-t", pane_id, check=False)
    retry = host_launch.without_effort(argv, kind, view)
    if retry is not None:
        print(
            "[subagent] launch failed on effort; retrying with the model default",
            file=sys.stderr,
        )
        if start(retry):
            return True
        view = tmux("capture-pane", "-p", "-t", pane_id, check=False)

    tail = "\n".join(view.splitlines()[-15:])
    print(f"[subagent] agent start failed for {name}\n--- pane ---\n{tail}", file=sys.stderr)
    return False


def launch(spec, target=None):
    """Create a window in the target session and start the Subagent in it."""
    name = spec["name"]
    cwd = spec["cwd"]
    kind = spec["engine"]["kind"]
    if kind == "claude":
        host_launch.trust_claude_dir(cwd)
    session = target or tmux_session()
    window, pane = tmux(
        "new-window", "-d", "-P", "-F", "#{window_id} #{pane_id}",
        "-t", f"{session}:", "-c", cwd, "-n", name,
    ).split()
    print(
        f"[subagent] {name} window {window} pane {pane} "
        f"model {spec['model']} effort {spec['effort']}",
        file=sys.stderr,
    )
    if not launch_tmux(name, pane, engine_argv(spec), spec["prompt"], cwd, kind=kind):
        return 2
    print(
        json.dumps(
            {
                "host": "tmux",
                "session": session,
                "window": window,
                "pane": pane,
                "name": name,
            }
        )
    )
    return 0


def main(argv):
    command = argv[0] if argv else "launch"
    if command == "launch":
        return launch(json.load(sys.stdin), argv[1] if len(argv) > 1 else None)
    if command == "notify" and len(argv) == 3:
        notify(argv[1], argv[2])
        return 0
    if command == "close" and len(argv) == 2:
        tmux("kill-window", "-t", argv[1])
        return 0
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

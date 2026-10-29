#!/usr/bin/env python3
"""Host extension: launch and address a Stage Subagent in a tmux window.

Reads the launch spec printed by scripts/subagent.py on stdin.

Usage:
    host.py launch [--remote-manager] [SESSION]
                                    # spec on stdin, prints {"window", "pane", ...}
    host.py notify PANE MESSAGE     # type a message into a marked pane
    host.py close WINDOW            # kill the Subagent's window

SESSION defaults to the calling agent's tmux session, taken from TMUX_PANE,
never whichever session is attached. With --remote-manager the Manager runs on
another machine: its address is never typed into here, and without TMUX_PANE
or SESSION the window goes to a detached
"subagents" session, created when missing.
"""

import json
import os
import subprocess
import sys
import time

# Launch mechanics shared with the other interactive host extensions.
EXTENSIONS_DIR = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
)
sys.path.insert(0, EXTENSIONS_DIR)
import host_launch  # noqa: E402
from host_launch import clip  # noqa: E402

HOST = os.path.abspath(__file__)
# Pane option launch sets on the Manager's and the Subagent's panes; notify
# types only into a pane that carries it.
NOTIFY_MARK = "@subagent-notify"
STARTUP_GRACE = 3  # seconds a tmux child must survive to count as launched
REMOTE_SESSION = "subagents"  # session for a remote Manager's Subagents


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


def mark_pane(pane):
    """Let notify type into pane: launch marks only the two panes it vouched for."""
    tmux("set-option", "-p", "-t", pane, NOTIFY_MARK, "1")


def manager_pane_error(pane):
    """Why pane cannot be this Manager's address, or None when it is."""
    pid = tmux("display-message", "-p", "-t", pane, "#{pane_pid}", check=False)
    return host_launch.manager_pane_error(pane, pid)


def notify(pane, message):
    """Type message into pane and submit it.

    A bracketed paste keeps multi-line messages from submitting line by line.
    Only a pane launch marked is typed into: anything else may be a human's
    input, and the Enter would send it.
    """
    mark = tmux("show-options", "-p", "-v", "-t", pane, NOTIFY_MARK, check=False)
    if mark != "1":
        sys.exit(
            f"notify: pane {pane} was not marked by launch as a Manager or "
            "Subagent pane; refusing to type into it"
        )
    buffer = f"subagent-{os.getpid()}"
    tmux("load-buffer", "-b", buffer, "-", input=message)
    tmux("paste-buffer", "-p", "-d", "-b", buffer, "-t", pane)
    time.sleep(0.3)  # let the TUI finish the paste before Enter submits it
    tmux("send-keys", "-t", pane, "Enter")


def launch_tmux(name, pane_id, argv, prompt, cwd, kind="pi", recado_bin_dir=None):
    """Start the agent in the tmux pane with the task as its first message.

    The pane remains after the agent exits, so a failed launch stays visible.
    """
    tmux("set-option", "-w", "-t", pane_id, "remain-on-exit", "on")

    def start(extra):
        command, temps = host_launch.child_command(name, prompt, kind, extra, recado_bin_dir)
        try:
            tmux("respawn-pane", "-k", "-t", pane_id, "-c", cwd, "--", *command)
        except BaseException:
            host_launch.remove_temp(*temps)
            raise

        deadline = time.monotonic() + STARTUP_GRACE
        while time.monotonic() < deadline:
            pane_state = subprocess.run(
                ["tmux", "display-message", "-p", "-t", pane_id,
                 "#{pane_id} #{pane_dead}"],
                capture_output=True, text=True, check=False,
            )
            if pane_state.returncode != 0 or pane_state.stdout.strip() != f"{pane_id} 0":
                host_launch.remove_temp(*temps)
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


def launch(spec, target=None, remote_manager=False):
    """Create a window in the target session and start the Subagent in it.

    A remote Manager's address is on another machine: it is neither checked
    nor marked here.
    """
    name = spec["name"]
    cwd = spec["cwd"]
    kind = spec["engine"]["kind"]
    error = None if remote_manager else manager_pane_error(spec["manager"])
    if error:
        print(f"[subagent] refusing to launch {name}: {error}", file=sys.stderr)
        return 2
    if kind == "claude":
        host_launch.trust_claude_dir(cwd)
    if target:
        session = target
    elif remote_manager and not os.environ.get("TMUX_PANE"):
        session = f"={REMOTE_SESSION}"
        if subprocess.run(["tmux", "has-session", "-t", session], capture_output=True).returncode:
            tmux("new-session", "-d", "-s", REMOTE_SESSION, "-c", cwd)
    else:
        session = tmux_session()
    window, pane = tmux(
        "new-window", "-d", "-P", "-F", "#{window_id} #{pane_id}",
        "-t", f"{session}:", "-c", cwd, "-n", name,
    ).split()
    print(
        f"[subagent] {name} window {window} pane {pane} "
        f"model {spec['model']} effort {spec['effort']}",
        file=sys.stderr,
    )
    argv = host_launch.engine_argv(spec, f"python3 {HOST} notify", f"{sys.executable} {HOST} notify")
    if not launch_tmux(name, pane, argv, spec["prompt"], cwd, kind=kind, recado_bin_dir=spec.get("recado_bin_dir")):
        return 2
    if not remote_manager:
        mark_pane(spec["manager"])
        mark_pane(pane)
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
        remote = "--remote-manager" in argv[1:]
        rest = [arg for arg in argv[1:] if arg != "--remote-manager"]
        return launch(json.load(sys.stdin), rest[0] if rest else None, remote)
    if command == "notify" and len(argv) == 3:
        notify(argv[1], argv[2])
        return 0
    if command == "close" and len(argv) == 2:
        tmux("kill-window", "-t", argv[1])
        return 0
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

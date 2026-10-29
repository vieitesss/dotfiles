#!/usr/bin/env python3
"""Host extension: launch and address a Stage Subagent in a Rex window.

Reads the launch spec printed by scripts/subagent.py on stdin.

Usage:
    host.py launch [SESSION]        # spec on stdin, prints {"window", "block", ...}
    host.py notify BLOCK MESSAGE    # paste a message into a marked block and submit
    host.py close WINDOW            # close the Subagent's window

    host.py remote-launch MACHINE [SESSION]   # spec on stdin: tmux on MACHINE
    host.py remote-close MACHINE WINDOW

SESSION defaults to the calling agent's Rex session, taken from REX_SESSION,
never whichever session the app shows. REX_SERVER, when set, selects the
server, as it does for every rex command.

The remote-* commands run the Subagent in tmux on an SSH host without Rex.
recado carries messages between the machines.
"""

import json
import os
import shlex
import shutil
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
STARTUP_GRACE = 3  # seconds a Rex child must survive to count as launched
# The skill's path on a remote machine, as the dotfiles install it.
REMOTE_TMUX_HOST = "~/.agents/skills/subagents/extensions/tmux/host.py"


def rex_bin():
    """rex on PATH, else the copy Rex names in REX_BIN_DIR inside its terminals."""
    found = shutil.which("rex")
    if found:
        return found
    bin_dir = os.environ.get("REX_BIN_DIR")
    if bin_dir and os.access(os.path.join(bin_dir, "rex"), os.X_OK):
        return os.path.join(bin_dir, "rex")
    sys.exit("rex not found on PATH or in REX_BIN_DIR")


def rex(*args, check=True, input=None):
    proc = subprocess.run(
        [rex_bin(), *args], capture_output=True, text=True, check=False, input=input
    )
    if check and proc.returncode != 0:
        sys.exit(f"rex {' '.join(args[:2])} failed: {clip(proc.stderr or proc.stdout)}")
    return proc.stdout


def rex_json(*args, check=True):
    try:
        return json.loads(rex(*args, check=check))
    except ValueError:
        return None


def calling_session():
    """Rex session of the calling agent, not whichever one the app shows."""
    session = os.environ.get("REX_SESSION")
    if not session:
        sys.exit("REX_SESSION is not set; run from the Manager's Rex terminal")
    return session


def marks_path():
    state = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(state, "subagents", "rex-notify-blocks")


def marked(block):
    try:
        with open(marks_path(), encoding="utf-8") as handle:
            return block in handle.read().split()
    except FileNotFoundError:
        return False


def mark_block(block):
    """Let notify type into block: launch marks only the two blocks it vouched for.

    Rex has no per-block user option, so the marks live in a local file. Block
    ids are never reused, so the file only grows by two lines per launch.
    """
    if marked(block):
        return
    path = marks_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(f"{block}\n")


def process(block):
    """The block's process report: child, foreground and last_exit, or None."""
    return rex_json("block", "call", "-b", block, "process", check=False)


def manager_pane_error(block):
    """Why block cannot be this Manager's address, or None when it is."""
    try:
        pid = process(block)["child"]["pid"]
    except (KeyError, TypeError):
        pid = None
    return host_launch.manager_pane_error(block, pid)


def notify(block, message):
    """Paste message into block and submit it.

    A paste event keeps multi-line messages from submitting line by line, and
    travels on stdin so it never shows in a process listing. Only a block
    launch marked is typed into: anything else may be a human's input, and
    the Enter would send it.
    """
    if not marked(block):
        sys.exit(
            f"notify: block {block} was not marked by launch as a Manager or "
            "Subagent block; refusing to type into it"
        )
    session = rex_json("block", "inspect", block, "--json")["session_id"]
    event = {"block_id": block, "event": {"type": "paste", "payload": {"text": message}}}
    rex("api", "call", "-s", session, "block.event", "-", input=json.dumps(event))
    time.sleep(0.3)  # let the TUI finish the paste before Enter submits it
    rex("send-key", "-s", session, "-b", block, "enter")


def start(name, session, cwd, argv, prompt, kind, recado_bin_dir=None):
    """Open a background window running the agent: (window, block, alive).

    The window stays open after the agent exits, so a failed launch stays
    visible; its ids go to stderr.
    """
    command, temps = host_launch.child_command(name, prompt, kind, argv, recado_bin_dir)
    try:
        created = rex_json(
            "window", "new", "-s", session, name, "-c", cwd,
            "--focus=false", "--keep-open", "--shell=none", "--json",
            "--", *command,
        )
    except BaseException:
        host_launch.remove_temp(*temps)
        raise
    window, block = created["window_id"], created["block_ids"][0]
    print(f"[subagent] {name} window {window} block {block}", file=sys.stderr)

    deadline = time.monotonic() + STARTUP_GRACE
    while time.monotonic() < deadline:
        state = process(block)
        if not state or state.get("last_exit") is not None:
            host_launch.remove_temp(*temps)
            return window, block, False
        time.sleep(0.25)
    return window, block, True


def launch(spec, target=None):
    """Create a background window in the target session and start the Subagent."""
    name = spec["name"]
    cwd = spec["cwd"]
    kind = spec["engine"]["kind"]
    error = manager_pane_error(spec["manager"])
    if error:
        print(f"[subagent] refusing to launch {name}: {error}", file=sys.stderr)
        return 2
    if kind == "claude":
        host_launch.trust_claude_dir(cwd)
    session = target or calling_session()
    print(
        f"[subagent] {name} model {spec['model']} effort {spec['effort']}",
        file=sys.stderr,
    )
    argv = host_launch.engine_argv(spec, f"python3 {HOST} notify", f"{sys.executable} {HOST} notify")
    window, block, alive = start(name, session, cwd, argv, spec["prompt"], kind, spec.get("recado_bin_dir"))
    if not alive:
        view = rex("capture", "-b", block, "--trim", check=False)
        retry = host_launch.without_effort(argv, kind, view)
        if retry is not None:
            print(
                "[subagent] launch failed on effort; retrying with the model default",
                file=sys.stderr,
            )
            rex("window", "close", window, check=False)
            window, block, alive = start(name, session, cwd, retry, spec["prompt"], kind, spec.get("recado_bin_dir"))
            if not alive:
                view = rex("capture", "-b", block, "--trim", check=False)
    if not alive:
        tail = "\n".join(view.splitlines()[-15:])
        print(
            f"[subagent] agent start failed for {name}\n--- block ---\n{tail}",
            file=sys.stderr,
        )
        return 2
    mark_block(spec["manager"])
    mark_block(block)
    print(
        json.dumps(
            {
                "host": "rex",
                "session": session,
                "window": window,
                "block": block,
                "name": name,
            }
        )
    )
    return 0


def ssh(machine, command, input=None):
    if not machine or machine.startswith("-"):
        sys.exit(f"not an SSH host: {machine!r}")
    return subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=30", machine, command],
        input=input, text=True, check=False, stdout=subprocess.PIPE,
    )


def remote_tmux(*args):
    return " ".join(["python3", REMOTE_TMUX_HOST, *map(shlex.quote, args)])


def remote_launch(spec, machine, target=None):
    """Launch in remote tmux and start recado's return route with a kickoff."""
    error = manager_pane_error(spec["manager"])
    if error:
        print(f"[subagent] refusing to launch {spec['name']}: {error}", file=sys.stderr)
        return 2
    args = ["launch", "--remote-manager", *([target] if target else [])]
    proc = ssh(machine, remote_tmux(*args), input=json.dumps(spec))
    if proc.returncode != 0:
        return proc.returncode
    result = json.loads(proc.stdout)
    result["machine"] = machine
    try:
        kickoff = subprocess.run(
            ["recado", "send", f"recado://{machine}/{spec['name']}",
             "Continue the brief; this opens the recado return route."],
            capture_output=True, text=True, check=False,
        )
        if kickoff.returncode:
            raise RuntimeError(clip(kickoff.stderr or kickoff.stdout))
    except (OSError, RuntimeError) as err:
        print(f"[subagent] recado kickoff failed: {err}; remote session: {json.dumps(result)}", file=sys.stderr)
        return 1
    result["kickoff"] = kickoff.stdout.strip()
    print(json.dumps(result))
    return 0


def main(argv):
    command = argv[0] if argv else "launch"
    if command == "launch":
        return launch(json.load(sys.stdin), argv[1] if len(argv) > 1 else None)
    if command == "notify" and len(argv) == 3:
        notify(argv[1], argv[2])
        return 0
    if command == "close" and len(argv) == 2:
        rex("window", "close", argv[1])
        return 0
    if command == "remote-launch" and len(argv) in (2, 3):
        return remote_launch(json.load(sys.stdin), argv[1], argv[2] if len(argv) == 3 else None)
    if command == "remote-close" and len(argv) == 3:
        return ssh(argv[1], remote_tmux("close", argv[2])).returncode
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

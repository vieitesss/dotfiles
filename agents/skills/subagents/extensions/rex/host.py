#!/usr/bin/env python3
"""Host extension: launch and close a Stage Subagent in a Rex window.

Usage:
    host.py launch [SESSION]            # spec on stdin, prints {"window", "block", ...}
    host.py remote-launch HOST [--session SESSION] PREP_ARGS...
                                        # brief on stdin: prepare and launch on HOST
    host.py close WINDOW [HOST]         # close the Subagent's window

launch opens the window in SESSION, else the calling agent's session from
REX_SESSION, never whichever session the app shows. REX_SERVER, when set,
selects the server, as it does for every rex command.

remote-launch runs a Stage on another Rex host. HOST is both the Rex host
label (`rex hosts`) and the recado machine name (`recado machine ls`); the
recado machine's SSH target carries preparation and launch, recado carries
messages, and `rex -S HOST` reaches the window afterwards.
"""

import json
import os
import shlex
import shutil
import socket
import subprocess
import sys
import time

EXTENSIONS_DIR = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
)
sys.path.insert(0, EXTENSIONS_DIR)
import host_launch  # noqa: E402
from host_launch import clip  # noqa: E402

STARTUP_GRACE = 3  # seconds a Rex child must survive to count as launched
# The skill's path on another host, as the dotfiles install it.
REMOTE_SKILL = "~/.agents/skills/subagents"
# The session a remote launch uses when none is named, created when missing.
REMOTE_SESSION = "subagents"
KICKOFF = "Continue the brief; this opens the recado return route."


def rex_bin():
    """rex on PATH, else the copy Rex names in REX_BIN_DIR inside its terminals."""
    found = shutil.which("rex")
    if found:
        return found
    bin_dir = os.environ.get("REX_BIN_DIR")
    if bin_dir and os.access(os.path.join(bin_dir, "rex"), os.X_OK):
        return os.path.join(bin_dir, "rex")
    sys.exit("rex not found on PATH or in REX_BIN_DIR")


def rex_run(*args):
    # Never start a fresh server: a stale REX_SERVER would get an empty one,
    # and the Manager's own server must stay untouched.
    return subprocess.run(
        [rex_bin(), "--autostart=false", *args],
        capture_output=True, text=True, check=False,
    )


def rex(*args, check=True):
    proc = rex_run(*args)
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


def remote_session(label):
    """The session labelled label on this server, created when missing."""
    sessions = (rex_json("ls", "--json") or {}).get("sessions", [])
    for session in sessions:
        if label in (session.get("label"), session.get("session_id")):
            return session["session_id"]
    return json.loads(rex("new", label, "-c", os.path.expanduser("~"), "--json"))["session_id"]


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


def start(name, session, cwd, argv, prompt, kind, recado_bin_dir=None):
    """Open a background window running the agent: (window, block, alive).

    The window stays open after the agent exits, so a failed launch stays
    visible; its ids go to stderr.
    """
    command, temps = host_launch.child_command(name, prompt, kind, argv, recado_bin_dir)
    try:
        proc = rex_run(
            "window", "new", "-s", session, name, "-c", cwd,
            "--focus=false", "--keep-open", "--shell=none", "--json",
            "--", *command,
        )
    except BaseException:
        host_launch.remove_temp(*temps)
        raise
    if proc.returncode != 0:
        host_launch.remove_temp(*temps)
        # A timed-out request may still have created the window.
        sys.exit(
            f"rex window new failed: {clip(proc.stderr or proc.stdout)}\n"
            f"check `rex window ls -s {session}` for a window named {name} "
            "and close it before relaunching"
        )
    created = json.loads(proc.stdout)
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


def launch(spec, target=None, remote=False):
    """Create a background window in the target session and start the Subagent.

    remote: the Manager runs on another machine and checked its own block
    there, so skip that check and default to the shared remote session.
    """
    name = spec["name"]
    cwd = spec["cwd"]
    kind = spec["engine"]["kind"]
    error = None if remote else manager_pane_error(spec["manager"])
    if error:
        print(f"[subagent] refusing to launch {name}: {error}", file=sys.stderr)
        return 2
    if kind == "claude":
        host_launch.trust_claude_dir(cwd)
    if remote:
        session = remote_session(target or REMOTE_SESSION)
    else:
        session = target or calling_session()
    print(
        f"[subagent] {name} model {spec['model']} effort {spec['effort']}",
        file=sys.stderr,
    )
    argv = host_launch.engine_argv(spec)
    window, block, alive = start(name, session, cwd, argv, spec["prompt"], kind, spec.get("recado_bin_dir"))
    if not alive:
        view = rex("capture", "-b", block, "--trim", "--unwrap", check=False)
        retry = host_launch.without_effort(argv, kind, view)
        if retry is not None:
            print(
                "[subagent] launch failed on effort; retrying with the model default",
                file=sys.stderr,
            )
            rex("window", "close", window, check=False)
            window, block, alive = start(name, session, cwd, retry, spec["prompt"], kind, spec.get("recado_bin_dir"))
            if not alive:
                view = rex("capture", "-b", block, "--trim", "--unwrap", check=False)
    if not alive:
        tail = "\n".join(view.splitlines()[-15:])
        print(
            f"[subagent] agent start failed for {name}\n--- block ---\n{tail}",
            file=sys.stderr,
        )
        return 2
    print(
        json.dumps(
            {
                "host": "rex",
                "session": session,
                "window": window,
                "block": block,
                "name": name,
                "report": spec["report"],
            }
        )
    )
    return 0


def recado_json(*args):
    proc = subprocess.run(
        ["recado", *args, "--json"], capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        sys.exit(f"recado {' '.join(args)} failed: {clip(proc.stderr or proc.stdout)}")
    return json.loads(proc.stdout)


def ssh_target(host):
    """The SSH target recado uses for machine host."""
    for machine in recado_json("machine", "ls").get("machines", []):
        if machine.get("name") == host and machine.get("kind") == "ssh":
            target = machine.get("target", "")
            if not target or target.startswith("-"):
                sys.exit(f"recado machine {host} has an unusable SSH target: {target!r}")
            return target
    sys.exit(f"no recado machine named {host}; run `recado machine add {host} ssh SSH_TARGET`")


def upstream_address():
    """This Manager's recado address as seen from another machine."""
    agent = recado_json("whoami").get("agent", "")
    if not agent:
        sys.exit("recado whoami cannot identify the Manager; restart it after recado skill setup")
    return f"recado+upstream://{socket.gethostname()}/{agent}"


def remote_launch(host, brief, prep_args, target=None):
    """Prepare and launch on host over SSH, then open recado's return route."""
    manager = os.environ.get("REX_BLOCK", "")
    error = manager_pane_error(manager)
    if error:
        print(f"[subagent] refusing to launch on {host}: {error}", file=sys.stderr)
        return 2
    prepare = [
        "python3", f"{REMOTE_SKILL}/scripts/subagent.py", *prep_args,
        "--extension", f"{REMOTE_SKILL}/extensions/rex.md",
        "--manager", manager, "--manager-recado", upstream_address(),
    ]
    start_args = ["launch", "--remote", *([target] if target else [])]
    # The brief travels on stdin, so the remote shell never parses it. A
    # leading ~ stays unquoted so the remote shell expands it.
    script = (
        'brief=$(mktemp) || exit 1; trap \'rm -f "$brief"\' 0; cat >"$brief"; '
        f'spec=$({shell_words(prepare)} "$(cat "$brief")") || exit 1; '
        f'printf "%s\\n" "$spec" | python3 {REMOTE_SKILL}/extensions/rex/host.py '
        f'{shell_words(start_args)}'
    )
    proc = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=30",
         ssh_target(host), script],
        input=brief, text=True, check=False, stdout=subprocess.PIPE,
    )
    if proc.returncode != 0:
        return proc.returncode
    result = json.loads(proc.stdout)
    result["machine"] = host
    kickoff = subprocess.run(
        ["recado", "send", f"recado://{host}/{result['name']}", KICKOFF],
        capture_output=True, text=True, check=False,
    )
    if kickoff.returncode:
        print(
            f"[subagent] recado kickoff failed: {clip(kickoff.stderr or kickoff.stdout)}; "
            f"remote window: {json.dumps(result)}",
            file=sys.stderr,
        )
        return 1
    result["kickoff"] = kickoff.stdout.strip()
    print(json.dumps(result))
    return 0


def shell_words(args):
    return " ".join(
        arg if arg.startswith("~/") and shlex.quote(arg[2:]) == arg[2:] else shlex.quote(arg)
        for arg in args
    )


def main(argv):
    command, args = (argv[0], argv[1:]) if argv else ("launch", [])
    if command == "launch":
        remote = "--remote" in args
        args = [arg for arg in args if arg != "--remote"]
        if len(args) <= 1:
            return launch(json.load(sys.stdin), args[0] if args else None, remote)
    if command == "remote-launch" and args:
        host, rest = args[0], args[1:]
        target = None
        if rest[:1] == ["--session"] and len(rest) > 1:
            target, rest = rest[1], rest[2:]
        if rest:
            return remote_launch(host, sys.stdin.read(), rest, target)
    if command == "close" and len(args) in (1, 2):
        server = ["-S", args[1]] if len(args) == 2 else []
        rex(*server, "window", "close", args[0])
        return 0
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

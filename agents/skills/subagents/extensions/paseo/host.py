#!/usr/bin/env python3
"""Host extension: launch and address a Stage Subagent on Paseo.

Reads the launch spec printed by scripts/subagent.py on stdin.

Usage:
    host.py launch [WORKSPACE]   # spec on stdin, prints {"agentId", ...}
    host.py send AGENT_ID MESSAGE   # validate, queue, and name the delivery log
    host.py pending                 # idle subagent-* agents and delivery state
    host.py archive AGENT_ID        # force-archive an accepted Subagent

WORKSPACE is an existing Paseo workspace id for the run. The helper refuses it
unless the daemon lists it and its root is the spec's cwd, because the CLI would
otherwise put that workspace's root in place of the prepared directory. Without
WORKSPACE the helper places the run itself: in the Manager's own workspace when
the target directory is the Manager's, otherwise in the workspace already rooted
at the target directory, otherwise in a new local workspace for it inside the
Manager's project. A local workspace points at an existing directory; it
creates no worktree.

`archive` forces the CLI to interrupt a session whose reporting turn is still
running; it keeps the history and is not a permission bypass.

The Paseo CLI is $PASEO_CLI when set, else `paseo` on PATH. On a same-daemon
launch, `paseo run` inherits PASEO_AGENT_ID as the caller. Across machines,
the supplied Markdown extension must carry an explicit return route; the
execution machine's environment does not identify the remote Manager.
"""

import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import host_launch  # noqa: E402
from host_launch import clip  # noqa: E402

DELIVER_WAIT = 3600  # seconds a queued message waits for an idle receiver
PICKUP_WAIT = 15  # seconds to see the receiver start the delivered turn


def run_cli(*args):
    """One Paseo CLI call, returning the completed process for the caller."""
    cli = os.environ.get("PASEO_CLI", "paseo")
    return subprocess.run([cli, *args], capture_output=True, text=True, check=False)


def paseo(*args, check=True):
    proc = run_cli(*args)
    if proc.returncode != 0:
        if not check:
            return None
        sys.exit(f"paseo {args[0]} failed: {clip(proc.stderr or proc.stdout)}")
    return proc.stdout


def reply_field(reply, field):
    """A string field out of `paseo run --json`, or None.

    The CLI renders its result as pretty-printed JSON on stdout and writes its
    own log lines to stderr, which paseo() captures separately, so the whole
    reply is one JSON object.
    """
    try:
        data = json.loads(reply or "")
    except ValueError:
        return None
    if not isinstance(data, dict):
        return None
    found = data.get(field)
    return found if isinstance(found, str) and found else None


def same_dir(left, right):
    return bool(left) and bool(right) and os.path.realpath(left) == os.path.realpath(right)


def workspaces():
    """Live workspaces the daemon lists, as dicts; empty when it cannot list."""
    listed = paseo("workspace", "ls", "--json", check=False)
    try:
        rows = json.loads(listed) if listed else []
    except ValueError:
        return []
    return [row for row in rows if isinstance(row, dict)] if isinstance(rows, list) else []


def rooted_at(listed, cwd):
    """The listed workspace rooted at cwd, or None."""
    for workspace in listed:
        if same_dir(workspace.get("cwd"), cwd):
            return workspace
    return None


def project_id(name):
    """The id of the one project the daemon lists under name, or None.

    Workspace listings name their project but carry no id, and
    `workspace create --project` takes only the id.
    """
    listed = paseo("project", "ls", "--json", check=False)
    try:
        rows = json.loads(listed) if listed else []
    except ValueError:
        return None
    if not isinstance(rows, list):
        return None
    ids = [
        row.get("projectId") for row in rows
        if isinstance(row, dict) and row.get("name") == name
        and isinstance(row.get("projectId"), str)
    ]
    return ids[0] if len(ids) == 1 else None


def project_workspace(cwd, project, title):
    """A new local workspace for cwd inside project; exits when none is made.

    `run --new-workspace local` would register cwd, a worktree and so its own
    git root, as a project of its own; creating the workspace under the
    Manager's project keeps every Stage in the Manager's project.
    """
    reply = paseo(
        "workspace", "create", "--isolation", "local", "--path", cwd,
        "--project", project, "--title", title, "--no-background", "--json",
    )
    created = reply_field(reply, "workspaceId")
    if not created:
        sys.exit(f"paseo workspace create returned no workspace id: {clip(reply)}")
    return created


def explicit_workspace(workspace_id, cwd):
    """Flags for an explicit workspace once its root is checked against cwd.

    The CLI replaces --cwd with the explicit workspace's own root, so an
    unvalidated id would silently run the Stage in another checkout. The id
    must name a workspace the daemon lists, rooted at the prepared directory.
    """
    for workspace in workspaces():
        if workspace.get("workspaceId") == workspace_id:
            root = workspace.get("cwd")
            if same_dir(root, cwd):
                return ["--workspace", workspace_id]
            sys.exit(
                f"workspace {clip(workspace_id)} is rooted at {clip(root)}, not "
                f"{clip(cwd)}; refusing to move the Stage"
            )
    sys.exit(
        f"no live workspace {clip(workspace_id)}; refusing to launch the Stage "
        "in an unknown workspace"
    )


def workspace_argv(cwd, explicit, title):
    """Paseo flags that put the run in the target directory.

    An agent-scoped run defaults to the caller's workspace and cwd, so --cwd
    alone is honored only when it names that same directory. Any other target
    (a worktree, another project) needs an explicit existing workspace or a new
    one, or the daemon would silently run the Stage in the caller's cwd. A new
    one joins the caller's project when the daemon can name it.
    """
    if explicit:
        return explicit_workspace(explicit, cwd)
    caller = os.environ.get("PASEO_AGENT_CWD")
    if not caller or same_dir(caller, cwd):
        return ["--cwd", cwd]
    listed = workspaces()
    known = rooted_at(listed, cwd)
    if known:
        return ["--workspace", known.get("workspaceId")]
    home = rooted_at(listed, caller)
    project = project_id(home.get("project")) if home else None
    if project:
        return ["--workspace", project_workspace(cwd, project, title)]
    print(
        f"[subagent] no project found for the caller at {caller}; creating a "
        f"local workspace at {cwd} as its own project (pass a workspace id to "
        "reuse one instead)",
        file=sys.stderr,
    )
    return ["--new-workspace", "local", "--cwd", cwd]


def engine_effort(spec):
    """The thinking level core already clamped for the engine, as a Paseo id.

    Pi carries it as --thinking and Claude Code as --effort; Paseo spells both
    --thinking.
    """
    argv = spec["engine"]["argv"]
    flag = "--effort" if spec["engine"]["kind"] == "claude" else "--thinking"
    return argv[argv.index(flag) + 1] if flag in argv else None


def run_argv(spec, workspace=None):
    """`paseo run` argv for a prepared spec.

    Paseo has no append-system-prompt flag, so spec["prompt"] carries the Stage
    role itself.
    """
    argv = ["run", "--background", "--json", "--title", spec["name"]]
    argv += host_launch.identity_env(spec) + workspace_argv(spec["cwd"], workspace, spec["name"])
    if spec["engine"]["kind"] == "claude":
        argv += ["--provider", "claude"]
        model = (spec["model"] or "").partition("/")[2]
        if model:
            argv += ["--model", model]
        # Keep Paseo's permission checks; auto reviews prompts instead of
        # asking, so an unattended Subagent can still run its report command.
        argv += ["--mode", "auto"]
    else:
        argv += ["--provider", "pi"]
        if spec["model"]:
            argv += ["--model", spec["model"]]
    effort = engine_effort(spec)
    if effort:
        argv += ["--thinking", effort]
    argv.append(spec["prompt"])
    return argv


def forced_archive(agent):
    """Stop a session with the history-preserving archive, without raising.

    Returns False when the CLI refuses, so the caller can keep the agent id in
    its diagnostic instead of losing it to an exit message.
    """
    return paseo("archive", "--force", agent, check=False) is not None


def launch(spec, workspace=None):
    manager = spec.get("manager")
    if not isinstance(manager, str) or not manager.strip() or manager.strip().startswith("%"):
        sys.exit(
            "Paseo launch needs the Manager's Paseo agent id, not a local tmux "
            "pane; prepare the spec with the Manager's explicit reporting route"
        )
    reply = paseo(*run_argv(spec, workspace))
    launched = reply_field(reply, "agentId")
    if not launched:
        sys.exit(f"paseo run returned no agent id: {clip(reply)}")
    landed = reply_field(reply, "cwd")
    if landed and not same_dir(landed, spec["cwd"]):
        if forced_archive(launched):
            fate = f"archived the misplaced agent {clip(launched)}"
        else:
            fate = f"agent {clip(launched)} could not be archived and may still run"
        sys.exit(
            f"paseo run landed in {clip(landed)}, not {clip(spec['cwd'])}; "
            f"{fate}; refusing a Stage that would edit another directory"
        )
    print(
        json.dumps(
            {"host": "paseo", "agentId": launched, "name": spec["name"]}
        )
    )
    return 0


def known_agent(agent):
    """The daemon's inspect record for agent, or None when it knows no agent.

    A mistyped Manager id used to vanish into the detached delivery below,
    whose failure no one ever saw. Validating here fails loudly in the
    sender's own turn instead.
    """
    reply = paseo("inspect", "--json", agent, check=False)
    try:
        data = json.loads(reply) if reply else None
    except ValueError:
        return None
    if not isinstance(data, dict) or data.get("error"):
        return None
    if not data.get("Id") and not data.get("id"):
        return None
    return data


def send(agent, message):
    """Queue a message for delivery once the agent is idle, without blocking.

    The daemon interrupts a running turn when a message arrives, cancelling
    the receiver's in-flight tool call, so a detached child delivers it
    later. The temp file carries long text and is removed by the child.
    """
    if not agent or not agent.strip() or agent.strip().startswith("%"):
        sys.exit(
            f"refusing to queue a message for {clip(agent)}: not a Paseo "
            "agent id (a tmux pane is not a Manager address)"
        )
    if known_agent(agent) is None:
        sys.exit(
            f"unknown Paseo agent {clip(agent)}: the Manager id is wrong; "
            "copy it exactly from the prompt and retry"
        )
    fd, path = tempfile.mkstemp(prefix="subagent-message-", suffix=".md")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(message)
    log_fd, log = tempfile.mkstemp(
        prefix=f"subagent-deliver-{agent}-", suffix=".log"
    )
    with os.fdopen(log_fd, "w", encoding="utf-8") as handle:
        handle.write(f"queued for {agent}: {clip(message)}\n")
    with open(log, "a", encoding="utf-8") as child_out:
        subprocess.Popen(
            [
                sys.executable, os.path.abspath(__file__),
                "deliver", agent, path, log,
            ],
            stdin=subprocess.DEVNULL,
            stdout=child_out,
            stderr=child_out,
            start_new_session=True,
        )
    print(f"[subagent] queued for {agent}; delivery log: {log}")
    return 0


def agent_status(agent):
    """The agent's daemon status ("running", "idle", ...), or None."""
    reply = paseo("inspect", "--json", agent, check=False)
    try:
        return json.loads(reply)["Status"] if reply else None
    except (ValueError, KeyError, TypeError):
        return None


def deliver(agent, path, log=None):
    """Send the message file once the agent is idle, then remove it.

    Deliveries to one agent take turns under a lock file: each waits for
    idle, sends, and holds the lock until the agent has picked the message
    up, so a second queued message waits for that turn to end instead of
    interrupting it. Past the wait limit it sends anyway: an interrupt beats
    a lost message. Every step is appended to the delivery log send() named,
    ending in DELIVERED or FAILED, so a lost message leaves its reason.
    """
    notes = None
    if log:
        notes = open(log, "a", encoding="utf-8")

    def note(text):
        if notes is not None:
            notes.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {text}\n")
            notes.flush()

    try:
        try:
            with open(path, encoding="utf-8") as handle:
                note(f"message: {clip(handle.read())}")
        except OSError as err:
            note(f"FAILED {agent}: cannot read the message file: {err}")
            return 1
        lock = os.path.join(
            tempfile.gettempdir(), f"subagent-deliver-{agent}.lock"
        )
        try:
            with open(lock, "w") as held:
                fcntl.flock(held, fcntl.LOCK_EX)
                note(f"waiting for {agent} to be idle")
                waited = run_cli("wait", "--timeout", str(DELIVER_WAIT), agent)
                note(
                    f"wait rc={waited.returncode}: "
                    f"{clip(waited.stderr or waited.stdout)}"
                )
                note(f"sending to {agent} (status {agent_status(agent)})")
                sent = run_cli("send", "--no-wait", agent, "--prompt-file", path)
                if sent.returncode != 0:
                    note(
                        f"FAILED {agent}: paseo send failed: "
                        f"{clip(sent.stderr or sent.stdout)}"
                    )
                    return 1
                deadline = time.monotonic() + PICKUP_WAIT
                while agent_status(agent) == "idle" and time.monotonic() < deadline:
                    time.sleep(0.5)
                note(f"DELIVERED {agent}")
        except OSError as err:
            note(f"FAILED {agent}: {err}")
            return 1
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
        if notes is not None:
            notes.close()
    return 0


def delivery_state(agent):
    """The last line of the newest delivery log for agent, if any."""
    prefix, suffix = f"subagent-deliver-{agent}-", ".log"
    try:
        names = os.listdir(tempfile.gettempdir())
    except OSError:
        return "no delivery log"
    logs = sorted(
        (name for name in names
         if name.startswith(prefix) and name.endswith(suffix)),
        key=lambda name: os.path.getmtime(
            os.path.join(tempfile.gettempdir(), name)
        ),
        reverse=True,
    )
    if not logs:
        return "no delivery log"
    try:
        with open(
            os.path.join(tempfile.gettempdir(), logs[0]), encoding="utf-8"
        ) as handle:
            lines = [line.strip() for line in handle if line.strip()]
    except OSError:
        return "no delivery log"
    return lines[-1] if lines else "no delivery log"


def pending():
    """Idle subagent-* agents and what their delivery log says about them.

    The Manager's cheap backstop for a completion notice that never arrived:
    an idle Subagent with no DELIVERED record either never reported or lost
    the message. Undelivered agents print first.
    """
    proc = run_cli("ls", "--json")
    if proc.returncode != 0:
        sys.exit(f"paseo ls failed: {clip(proc.stderr or proc.stdout)}")
    try:
        rows = json.loads(proc.stdout) if proc.stdout.strip() else []
    except ValueError:
        rows = []
    if not isinstance(rows, list):
        rows = []
    idle = [
        row for row in rows
        if isinstance(row, dict)
        and str(row.get("name", "")).startswith("subagent-")
        and row.get("status") == "idle"
    ]
    if not idle:
        print("[subagent] no idle subagent-* agents")
        return 0
    states = [(row, delivery_state(row.get("id", ""))) for row in idle]
    states.sort(key=lambda item: "DELIVERED" in item[1])
    for row, state in states:
        print(f"{row.get('name')} {row.get('id')} idle: {state}")
    return 0


def main(argv):
    command = argv[0] if argv else "launch"
    if command == "launch" and len(argv) <= 2:
        return launch(json.load(sys.stdin), argv[1] if len(argv) == 2 else None)
    if command == "send" and len(argv) == 3:
        return send(argv[1], argv[2])
    if command == "deliver" and len(argv) in (3, 4):
        return deliver(argv[1], argv[2], argv[3] if len(argv) == 4 else None)
    if command == "pending" and len(argv) == 1:
        return pending()
    if command == "archive" and len(argv) == 2:
        paseo("archive", "--force", argv[1])
        return 0
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

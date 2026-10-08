#!/usr/bin/env python3
"""Host extension: launch and address a Stage Subagent on Paseo.

Reads the launch spec printed by scripts/subagent.py on stdin.

Usage:
    host.py launch [WORKSPACE]   # spec on stdin, prints {"agentId", ...}
    host.py send AGENT_ID MESSAGE   # nonblocking follow-up or answer
    host.py archive AGENT_ID        # force-archive an accepted Subagent

WORKSPACE is an existing Paseo workspace id for the run. The helper refuses it
unless the daemon lists it and its root is the spec's cwd, because the CLI would
otherwise put that workspace's root in place of the prepared directory. Without
WORKSPACE the helper places the run itself: in the Manager's own workspace when
the target directory is the Manager's, otherwise in the workspace already rooted
at the target directory, otherwise in a new local workspace for it. A local
workspace points at an existing directory; it creates no worktree.

`archive` forces the CLI to interrupt a session whose reporting turn is still
running; it keeps the history and is not a permission bypass.

The Paseo CLI is $PASEO_CLI when set, else `paseo` on PATH. On a same-daemon
launch, `paseo run` inherits PASEO_AGENT_ID as the caller. Across machines,
the supplied Markdown extension must carry an explicit return route; the
execution machine's environment does not identify the remote Manager.
"""

import json
import os
import subprocess
import sys
import tempfile

DETAIL_LIMIT = 2000


def clip(text, limit=DETAIL_LIMIT):
    """A failure detail capped at limit characters; a length limit, not redaction."""
    text = (text or "").strip()
    return text if len(text) <= limit else f"{text[:limit]}…"


def paseo(*args, check=True):
    cli = os.environ.get("PASEO_CLI", "paseo")
    proc = subprocess.run([cli, *args], capture_output=True, text=True, check=False)
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


def existing_workspace(cwd):
    """A live workspace already rooted at cwd, if the daemon reports one."""
    for workspace in workspaces():
        if same_dir(workspace.get("cwd"), cwd):
            return workspace.get("workspaceId")
    return None


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


def workspace_argv(cwd, explicit):
    """Paseo flags that put the run in the target directory.

    An agent-scoped run defaults to the caller's workspace and cwd, so --cwd
    alone is honored only when it names that same directory. Any other target
    (a worktree, another project) needs an explicit existing workspace or a new
    local one, or the daemon would silently run the Stage in the caller's cwd.
    """
    if explicit:
        return explicit_workspace(explicit, cwd)
    caller = os.environ.get("PASEO_AGENT_CWD")
    if not caller or same_dir(caller, cwd):
        return ["--cwd", cwd]
    known = existing_workspace(cwd)
    if known:
        return ["--workspace", known]
    print(
        f"[subagent] no workspace rooted at {cwd}; creating a local one "
        "(pass a workspace id to reuse one instead)",
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
    argv += workspace_argv(spec["cwd"], workspace)
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


def send(agent, message):
    """Send a message without waiting, through a temp file for long text."""
    fd, path = tempfile.mkstemp(prefix="subagent-message-", suffix=".md")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(message)
        paseo("send", "--no-wait", agent, "--prompt-file", path)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
    return 0


def main(argv):
    command = argv[0] if argv else "launch"
    if command == "launch" and len(argv) <= 2:
        return launch(json.load(sys.stdin), argv[1] if len(argv) == 2 else None)
    if command == "send" and len(argv) == 3:
        return send(argv[1], argv[2])
    if command == "archive" and len(argv) == 2:
        paseo("archive", "--force", argv[1])
        return 0
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Host extension: launch and address a Stage Subagent in a herdr tab.

Reads the launch spec printed by scripts/subagent.py on stdin.

Usage:
    host.py launch [WORKSPACE] [TIMEOUT_MS]   # spec on stdin, prints ids
    host.py notify TARGET MESSAGE            # prompt the Manager's agent
    host.py close TAB                        # close the Subagent's tab

WORKSPACE defaults to the calling agent's workspace, taken from
HERDR_WORKSPACE_ID, never whichever workspace is focused in the UI.
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

DEFAULT_TIMEOUT_MS = 30000
BUSY_RETRY_SECONDS = 30


def clip(text, limit=2000):
    """A failure detail capped at limit characters; a length limit, not redaction."""
    text = (text or "").strip()
    return text if len(text) <= limit else f"{text[:limit]}…"


def herdr(*args, check=True):
    proc = subprocess.run(["herdr", *args], capture_output=True, text=True, check=False)
    if check and proc.returncode != 0:
        sys.exit(
            f"herdr {' '.join(args[:2])} failed: {clip(proc.stderr or proc.stdout)}"
        )
    return proc.stdout


def herdr_json(*args):
    return json.loads(herdr(*args))


def parent_workspace():
    """Workspace the calling agent runs in, never whichever one has UI focus."""
    workspace = os.environ.get("HERDR_WORKSPACE_ID")
    if not workspace:
        sys.exit("HERDR_WORKSPACE_ID is not set; run from the Manager's herdr pane")
    return workspace


def claude_extra(spec):
    """Claude Code flags that let the Subagent report and edit its report."""
    return [
        "--allowedTools",
        "Bash(herdr agent prompt *)",
        f"Edit(/{spec['report']})",
    ]


def engine_argv(spec):
    argv = list(spec["engine"]["argv"])
    if spec["engine"]["kind"] == "claude":
        argv += claude_extra(spec)
    return argv


def start(name, pane_id, argv, timeout_ms=DEFAULT_TIMEOUT_MS, kind="pi"):
    """Start the agent in the pane; on failure show its own error and report it."""

    def run(extra):
        return subprocess.run(
            [
                "herdr", "agent", "start", name, "--kind", kind,
                "--pane", pane_id, "--timeout", str(timeout_ms), "--", *extra,
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    started = time.monotonic()
    proc = run(argv)
    while proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip()
        if "agent_pane_busy" not in detail or time.monotonic() - started >= BUSY_RETRY_SECONDS:
            break
        time.sleep(0.25)
        proc = run(argv)
    else:
        return True

    view = herdr(
        "pane", "read", pane_id, "--source", "recent", "--lines", "15", check=False
    )
    detail = clip(proc.stderr.strip() or proc.stdout.strip())

    # If the effort level caused the failure, retry with the model's own
    # default before giving up.
    retry = host_launch.without_effort(argv, kind, view)
    if retry is not None:
        print(
            "[subagent] launch failed on effort; retrying with the model default",
            file=sys.stderr,
        )
        proc = run(retry)
        if proc.returncode == 0:
            return True
        detail = clip(proc.stderr.strip() or proc.stdout.strip())
        view = herdr(
            "pane", "read", pane_id, "--source", "recent", "--lines", "15", check=False
        )

    print(
        f"[subagent] agent start failed for {name}: {detail}\n--- pane ---\n{view}",
        file=sys.stderr,
    )
    return False


def launch(spec, target=None, timeout_ms=DEFAULT_TIMEOUT_MS):
    """Create a non-focused tab and start the Subagent in it."""
    workspace = target or parent_workspace()
    kind = spec["engine"]["kind"]
    if kind == "claude":
        host_launch.trust_claude_dir(spec["cwd"])
    tab = herdr_json(
        "tab", "create",
        "--workspace", workspace,
        "--cwd", spec["cwd"],
        "--label", spec["name"],
        "--no-focus",
    )["result"]
    pane_id = tab["root_pane"]["pane_id"]
    tab_id = tab["tab"]["tab_id"]
    print(
        f"[subagent] {spec['name']} tab {tab_id} pane {pane_id} "
        f"model {spec['model']} effort {spec['effort']}",
        file=sys.stderr,
    )
    if not start(spec["name"], pane_id, engine_argv(spec), timeout_ms, kind=kind):
        return 2
    herdr("agent", "prompt", spec["name"], spec["prompt"])
    print(
        json.dumps(
            {
                "host": "herdr",
                "workspace": workspace,
                "tab": tab_id,
                "pane": pane_id,
                "name": spec["name"],
            }
        )
    )
    return 0


def main(argv):
    command = argv[0] if argv else "launch"
    if command == "launch":
        target = argv[1] if len(argv) > 1 else None
        timeout = int(argv[2]) if len(argv) > 2 else DEFAULT_TIMEOUT_MS
        return launch(json.load(sys.stdin), target, min(max(timeout, 1000), 300000))
    if command == "notify" and len(argv) == 3:
        herdr("agent", "prompt", argv[1], argv[2])
        return 0
    if command == "close" and len(argv) == 2:
        herdr("tab", "close", argv[1])
        return 0
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

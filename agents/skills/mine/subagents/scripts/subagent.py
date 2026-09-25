#!/usr/bin/env python3
"""Launch a pi subagent in a new herdr tab or tmux window and return immediately.

Jev (TypeSafe) reads the task and picks the subagent kind, model, thinking
effort, and which skills to load. The --skill flag may override the skills.

Usage:
    subagent.py "task for the subagent" [--skill NAME]...
                [--cwd DIR] [--workspace ID]
                [--timeout MS] [--dry-run]
    subagent.py --close TAB_ID
    subagent.py --notify PANE_ID MESSAGE

Creates a new tab (herdr) or window (tmux) in the calling agent's workspace or
session, starts a pi agent there, submits the task, prints the tab id, and
exits. The parent does not wait. Close the tab later with --close. In tmux,
children report back with --notify, which types MESSAGE into the parent pane.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

KINDS = {
    "research": "You are a research subagent. Investigate and report findings. Do not modify files.",
    "implement": "You are an implementation subagent. Make the code changes the task requires.",
    "write": "You are a writing subagent. Produce the requested prose or documentation.",
}

MODELS = {
    "opencode-go/mimo-v2.6-flash": "Trivial or mechanical, fully specified tasks that need no real reasoning and where speed matters.",
    "opencode-go/deepseek-v4.1-flash": "The default for most tasks: well-scoped everyday coding, writing, and research, including straightforward multi-step work. Prefer this unless a stronger model is clearly needed.",
    "github-copilot/gpt-6-luna": "The strongest model for ordinary difficult work: substantial multi-step tasks that need careful reasoning, or moderately unclear tasks with ordinary stakes. Choose this when a task is hard, large, or somewhat vague.",
    "claude-code/opus": "Reserved for genuinely exceptional tasks only: production-critical or otherwise high-stakes work, especially when the right approach is genuinely unclear. Choose this when an error would be costly and cheaper models are likely to fail.",
}

EFFORTS = {
    "minimal": "Bare minimum thinking; near-mechanical work.",
    "low": "A little thinking; simple, well-specified tasks.",
    "medium": "Moderate thinking; everyday tasks.",
    "high": "Careful thinking; multi-step tasks.",
    "xhigh": "Deep thinking; hard tasks.",
    "max": "Maximum thinking; the hardest or highest-stakes tasks.",
}

SKILL_THRESHOLD = 0.5  # Noul probability at or above which a skill is selected

SCRIPT = os.path.abspath(__file__)
STARTUP_GRACE = 3  # seconds a tmux child must survive to count as launched

CLAUDE_PROVIDER = "claude-code"
CLAUDE_EFFORTS = ["low", "medium", "high", "xhigh", "max"]
THINKING_ORDER = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]


def model_thinking_levels(model_id):
    """Thinking levels a model supports, per pi's models store. None if unknown."""
    provider, _, name = model_id.partition("/")
    path = os.path.expanduser("~/.pi/agent/models-store.json")
    try:
        with open(path, encoding="utf-8") as handle:
            store = json.load(handle)
    except (OSError, ValueError):
        return None
    model = next(
        (
            entry
            for entry in store.get(provider, {}).get("models", [])
            if entry.get("id") == name
        ),
        None,
    )
    if model is None:
        return None
    if not model.get("reasoning"):
        return ["off"]
    thinking_map = model.get("thinkingLevelMap") or {}
    return [
        level
        for level in THINKING_ORDER
        if thinking_map.get(level, "") is not None
        and (level not in ("xhigh", "max") or level in thinking_map)
    ]


def clamp_effort(level, supported):
    """Nearest supported level, searching up before down, like pi does."""
    if level in supported:
        return level
    if level not in THINKING_ORDER:
        return supported[0] if supported else None
    start = THINKING_ORDER.index(level)
    for candidate in THINKING_ORDER[start:]:
        if candidate in supported:
            return candidate
    for candidate in reversed(THINKING_ORDER[:start]):
        if candidate in supported:
            return candidate
    return supported[0] if supported else None


# --------------------------------------------------------------- herdr


def herdr(*args, check=True):
    proc = subprocess.run(["herdr", *args], capture_output=True, text=True, check=False)
    if check and proc.returncode != 0:
        sys.exit(
            f"herdr {' '.join(args)} failed: {proc.stderr.strip() or proc.stdout.strip()}"
        )
    return proc.stdout


def herdr_json(*args):
    return json.loads(herdr(*args))


def parent_workspace():
    """Workspace the calling agent runs in, not whichever one has UI focus.

    Herdr sets HERDR_WORKSPACE_ID in every pane, so prefer that. The focused
    workspace is only a fallback for callers running outside a herdr pane.
    """
    workspace = os.environ.get("HERDR_WORKSPACE_ID")
    if workspace:
        return workspace
    for ws in herdr_json("workspace", "list")["result"]["workspaces"]:
        if ws["focused"]:
            return ws["workspace_id"]
    sys.exit("no focused herdr workspace")


# --------------------------------------------------------------- tmux


def multiplexer():
    """herdr or tmux, whichever the calling agent runs in (herdr wins)."""
    if os.environ.get("HERDR_ENV"):
        return "herdr"
    if os.environ.get("TMUX"):
        return "tmux"
    sys.exit("subagent.py must run inside herdr or tmux")


def tmux(*args, check=True, input=None):
    proc = subprocess.run(
        ["tmux", *args], capture_output=True, text=True, check=False, input=input
    )
    if check and proc.returncode != 0:
        sys.exit(
            f"tmux {' '.join(args)} failed: {proc.stderr.strip() or proc.stdout.strip()}"
        )
    return proc.stdout.strip()


def tmux_session():
    """tmux session of the calling agent's pane, not whichever one is attached."""
    pane = os.environ.get("TMUX_PANE")
    return tmux("display-message", "-p", *(["-t", pane] if pane else []), "#{session_id}")


def tmux_notify(pane, message):
    """Type message into pane and submit it, like `herdr agent prompt`.

    A bracketed paste keeps multi-line messages from submitting line by line.
    """
    buffer = f"subagent-{os.getpid()}"
    tmux("load-buffer", "-b", buffer, "-", input=message)
    tmux("paste-buffer", "-p", "-d", "-b", buffer, "-t", pane)
    time.sleep(0.3)  # let the TUI finish the paste before Enter submits it
    tmux("send-keys", "-t", pane, "Enter")


# --------------------------------------------------------------- skills


def read_frontmatter(path):
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read(8192)
    except OSError:
        return None, None
    if not text.startswith("---"):
        return None, None
    end = text.find("\n---", 3)
    if end == -1:
        return None, None

    name = description = None
    lines = text[3:end].splitlines()
    for index, line in enumerate(lines):
        if line.startswith("name:"):
            name = line.split(":", 1)[1].strip().strip("\"'")
        elif line.startswith("description:"):
            value = line.split(":", 1)[1].strip()
            if value in ("|", ">", "|-", ">-"):
                parts = []
                for continuation in lines[index + 1 :]:
                    if continuation.startswith((" ", "\t")):
                        parts.append(continuation.strip())
                    elif continuation.strip():
                        break
                description = " ".join(parts)
            else:
                description = value.strip("\"'")
    return name, description


def discover_skills(cwd):
    home = os.path.expanduser("~")
    roots = [
        os.path.join(home, ".pi/agent/skills"),
        os.path.join(home, ".agents/skills"),
    ]
    current = os.path.abspath(cwd)
    while True:
        roots.append(os.path.join(current, ".pi/skills"))
        roots.append(os.path.join(current, ".agents/skills"))
        parent = os.path.dirname(current)
        if parent == current or os.path.isdir(os.path.join(current, ".git")):
            break
        current = parent

    skills = {}
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root, followlinks=True):
            if "SKILL.md" not in filenames:
                continue
            name, description = read_frontmatter(os.path.join(dirpath, "SKILL.md"))
            if name and description and name not in skills:
                skills[name] = {"path": dirpath, "description": description[:300]}
            dirnames[:] = []  # a skill directory contains no nested skills
    return skills


# --------------------------------------------------------------- jev


def jev(state, questions):
    key = os.environ.get("TYPESAFE_API_KEY")
    if not key:
        raise RuntimeError("TYPESAFE_API_KEY is not set")
    body = json.dumps(
        {"state": state, "model": "jev-latest", "questions": questions}
    ).encode()
    request = urllib.request.Request(
        "https://api.typesafe.ai/v1/systemone",
        data=body,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)["answers"]


def jev_profile(task, skills):
    model_criteria = {}
    for model_id, when in MODELS.items():
        levels = model_thinking_levels(model_id)
        model_criteria[model_id] = (
            f"{when} (thinking: {', '.join(levels)})" if levels else when
        )

    questions = {
        "kind": {
            "type": "choice",
            "instructions": "What kind of subagent should handle this task?",
            "criteria": {
                "research": "Investigate a question or codebase and report findings; do not change files.",
                "implement": "Change code to add, fix, or refactor behavior.",
                "write": "Write prose, documentation, or a summary rather than code.",
            },
        },
        "model": {
            "type": "choice",
            "instructions": "Which model should run this task, given its difficulty?",
            "criteria": model_criteria,
        },
        "effort": {
            "type": "choice",
            "instructions": "Which thinking effort does this task need?",
            "criteria": EFFORTS,
        },
    }
    for name, info in skills.items():
        questions[f"skill:{name}"] = {
            "type": "noul",
            "instructions": f"Does the task need the `{name}` skill? {info['description']}",
            "criteria": {
                "true": "The task matches this skill's purpose.",
                "false": "It does not.",
            },
        }

    answers = jev(task, questions)
    return {
        "kind": answers["kind"]["choice"],
        "model": answers["model"]["choice"],
        "effort": answers["effort"]["choice"],
        "skills": [
            key.split(":", 1)[1]
            for key, answer in answers.items()
            if key.startswith("skill:") and answer.get("noul", 0) >= SKILL_THRESHOLD
        ],
    }


def choose_profile(args, skills):
    try:
        profile = jev_profile(args.task, skills)
    except (urllib.error.URLError, KeyError, ValueError, RuntimeError) as err:
        print(
            f"[subagent] jev unavailable ({err}); using pi defaults",
            file=sys.stderr,
        )
        profile = {
            "kind": "implement",
            "model": None,
            "effort": None,
            "skills": None,
        }
    if args.skill is not None:
        profile["skills"] = args.skill

    profile["kind"] = profile["kind"] if profile["kind"] in KINDS else "implement"
    profile["model"] = profile["model"] if profile["model"] in MODELS else None
    profile["effort"] = profile["effort"] if profile["effort"] in EFFORTS else None

    # A model may not offer every level; clamp to the nearest one it supports
    # instead of letting pi silently adjust (or fail on) the launch.
    if profile["model"] and profile["effort"]:
        levels = model_thinking_levels(profile["model"])
        if levels is not None and profile["effort"] not in levels:
            clamped = clamp_effort(profile["effort"], levels)
            print(
                f"[subagent] {profile['model']} has no {profile['effort']} effort; "
                f"using {clamped or 'model default'}",
                file=sys.stderr,
            )
            profile["effort"] = None if clamped in (None, "off") else clamped
    return profile


def is_claude(profile):
    return (profile["model"] or "").partition("/")[0] == CLAUDE_PROVIDER


def claude_args(profile, mux="herdr"):
    args = ["--append-system-prompt", KINDS[profile["kind"]]]
    if profile["model"]:
        args += ["--model", profile["model"].partition("/")[2]]
    if profile["effort"]:
        args += ["--effort", clamp_effort(profile["effort"], CLAUDE_EFFORTS)]
    # Let reports to the parent run without a permission prompt, or they stall.
    report = "herdr agent prompt" if mux == "herdr" else f"{SCRIPT} --notify"
    args += ["--allowedTools", f"Bash({report} *)"]
    return args


def trust_claude_dir(cwd):
    """Pre-accept Claude Code's workspace trust dialog for cwd.

    Interactive claude has no flag to skip the dialog; it reads
    projects[<path>].hasTrustDialogAccepted from ~/.claude.json.
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


def pi_args(profile):
    args = ["--append-system-prompt", KINDS[profile["kind"]]]
    if profile["model"]:
        args += ["--model", profile["model"]]
    if profile["effort"]:
        args += ["--thinking", profile["effort"]]
    return args


def pane_lines(parent_pane, name, mux="herdr"):
    """How a child reaches a parent without intercom: typing into its pane."""
    target = parent_pane or "<parent-pane-id>"
    send = "herdr agent prompt" if mux == "herdr" else f"{SCRIPT} --notify"
    lines = []
    if not parent_pane:
        lines.append("Find your parent agent's pane id with `herdr agent list`.")
    lines += [
        f"Your parent agent runs in {mux} pane {target}; you are subagent "
        f"{name}. Reach the parent by prompting its pane through Bash:",
        "",
        "```sh",
        f'{send} {target} "[{name}] TASK COMPLETE: <summary>"',
        f'{send} {target} "[{name}] QUESTION: <question>"',
        "```",
        "",
        "When the task is finished, send your final result that way. When "
        "blocked on a question, send it, then end your turn; the parent's "
        "answer arrives as your next prompt. Always start the message with "
        f"`[{name}]`. For long results, write them to a file and send its "
        "path.",
    ]
    if mux == "herdr":
        lines[-1] += (
            " If herdr rejects the prompt (for example `agent_blocked`), wait "
            "a few seconds and retry."
        )
    lines[-1] += " Reporting this way is mandatory, not optional."
    return lines


def subagent_prompt(task, profile, parent_session, name, parent_pane=None, mux="herdr"):
    """Task prompt, prefixed with the skills to use and how to reach the parent."""
    lines = []
    if profile["skills"]:
        lines.append(f"Use these skills: {', '.join(profile['skills'])}.")
    # Intercom only works between two pi agents. A Claude child has no intercom
    # tool, and a parent without an intercom session (e.g. Claude) never
    # receives intercom messages, so everything else reports through its pane.
    if is_claude(profile) or not parent_session:
        lines += pane_lines(parent_pane, name, mux)
        return "\n".join(lines) + "\n\n" + task
    lines.append(f"Your parent agent is intercom session {parent_session}.")
    lines.append(
        "Use pi-intercom to report: when the task is finished, send your final "
        "result to the parent session with `intercom send` (fire-and-forget); "
        "when blocked on a question, `intercom ask` the parent. "
        "Reporting via intercom is mandatory, not optional. "
    )
    return "\n".join(lines) + "\n\n" + task


# --------------------------------------------------------------- main


def without_effort(argv, kind, view):
    """argv minus the effort flag if the pane shows the level made it fail, else None.

    Only error lines count; a herdr pane echoes the command line, which always
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


def launch(name, pane_id, argv, timeout_ms=30000, kind="pi"):
    """Start the agent in the pane; on failure show its own error and report it."""

    def start(extra):
        return subprocess.run(
            [
                "herdr",
                "agent",
                "start",
                name,
                "--kind",
                kind,
                "--pane",
                pane_id,
                "--timeout",
                str(timeout_ms),
                "--",
                *extra,
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    started = time.monotonic()
    proc = start(argv)
    while proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip()
        if "agent_pane_busy" not in detail or time.monotonic() - started >= 30:
            break
        time.sleep(0.25)
        proc = start(argv)
    else:
        return True

    view = herdr(
        "pane", "read", pane_id, "--source", "recent", "--lines", "15", check=False
    )
    detail = proc.stderr.strip() or proc.stdout.strip()

    # If the effort level caused the failure, retry with the model's own
    # default before giving up.
    retry = without_effort(argv, kind, view)
    if retry is not None:
        print(
            "[subagent] launch failed on effort; retrying with the model default",
            file=sys.stderr,
        )
        proc = start(retry)
        if proc.returncode == 0:
            return True
        detail = proc.stderr.strip() or proc.stdout.strip()
        view = herdr(
            "pane", "read", pane_id, "--source", "recent", "--lines", "15", check=False
        )

    print(
        f"[subagent] agent start failed for {name}: {detail}\n--- pane ---\n{view}",
        file=sys.stderr,
    )
    return False


def launch_tmux(name, pane_id, argv, prompt, cwd, kind="pi"):
    """Start the agent in the tmux pane with the task as its first message.

    tmux has no `agent start`/`agent prompt`, so the task goes on the agent's
    command line instead. It travels through a temp file because tmux rejects
    over-long commands, and a login shell gives the child the user's
    environment rather than the tmux server's. The pane remains after the agent
    exits, so a failed launch stays visible.
    """
    tmux("set-option", "-w", "-t", pane_id, "remain-on-exit", "on")
    shell = os.environ.get("SHELL", "/bin/sh")
    script = 'prompt=$(cat "$1"); rm -f "$1"; shift; exec "$@" "$prompt"'

    def start(extra):
        fd, path = tempfile.mkstemp(prefix=f"{name}-", suffix=".md")
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(prompt)
        tmux(
            "respawn-pane", "-k", "-t", pane_id, "-c", cwd, "--",
            shell, "-lc", script, name, path, kind, *extra, "--",
        )
        deadline = time.monotonic() + STARTUP_GRACE
        while time.monotonic() < deadline:
            if tmux("display-message", "-p", "-t", pane_id, "#{pane_dead}") == "1":
                return False
            time.sleep(0.25)
        return True

    if start(argv):
        return True
    view = tmux("capture-pane", "-p", "-t", pane_id, check=False)
    retry = without_effort(argv, kind, view)
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("task", nargs="?")
    parser.add_argument("--skill", action="append")
    parser.add_argument("--cwd", default=os.getcwd())
    parser.add_argument("--workspace")
    parser.add_argument("--timeout", type=int, default=30000)
    parser.add_argument("--close", metavar="TAB_ID")
    parser.add_argument("--notify", nargs=2, metavar=("PANE_ID", "MESSAGE"))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--keep", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--lines", type=int, default=40, help=argparse.SUPPRESS)
    args = parser.parse_args()

    if args.notify:
        tmux_notify(*args.notify)
        return 0
    if args.close:
        if multiplexer() == "herdr":
            herdr("tab", "close", args.close)
        else:
            tmux("kill-window", "-t", args.close)
        return 0
    if not args.task:
        parser.error("task is required")

    skills = discover_skills(args.cwd)
    profile = choose_profile(args, skills)

    if args.dry_run:
        print(json.dumps(profile, indent=2))
        return 0

    mux = multiplexer()
    name = f"subagent-{profile['kind']}-{os.getpid()}"
    if is_claude(profile):
        trust_claude_dir(args.cwd)
        kind, argv = "claude", claude_args(profile, mux)
    else:
        kind, argv = "pi", pi_args(profile)
    parent_session = os.environ.get("PI_INTERCOM_SESSION_ID") or os.environ.get(
        "PI_SESSION_ID"
    )
    parent_pane = os.environ.get("HERDR_PANE_ID" if mux == "herdr" else "TMUX_PANE")
    prompt = subagent_prompt(args.task, profile, parent_session, name, parent_pane, mux)

    if mux == "tmux":
        session = args.workspace or tmux_session()
        tab_id, pane_id = tmux(
            "new-window", "-d", "-P", "-F", "#{window_id} #{pane_id}",
            "-t", f"{session}:", "-c", args.cwd, "-n", name,
        ).split()
        print(
            f"[subagent] {name} window {tab_id} pane {pane_id} profile {profile}",
            file=sys.stderr,
        )
        if not launch_tmux(name, pane_id, argv, prompt, args.cwd, kind=kind):
            return 2
    else:
        workspace = args.workspace or parent_workspace()
        start_timeout = min(max(args.timeout, 1000), 300000)
        tab = herdr_json(
            "tab",
            "create",
            "--workspace",
            workspace,
            "--cwd",
            args.cwd,
            "--label",
            name,
            "--no-focus",
        )["result"]
        pane_id = tab["root_pane"]["pane_id"]
        tab_id = tab["tab"]["tab_id"]
        print(
            f"[subagent] {name} tab {tab_id} pane {pane_id} profile {profile}",
            file=sys.stderr,
        )
        if not launch(name, pane_id, argv, timeout_ms=start_timeout, kind=kind):
            return 2
        herdr("agent", "prompt", name, prompt)
    print(
        f"[subagent] launched; close with {sys.argv[0]} --close {tab_id}",
        file=sys.stderr,
    )
    return 0

if __name__ == "__main__":
    sys.exit(main())

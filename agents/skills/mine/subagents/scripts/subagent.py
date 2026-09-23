#!/usr/bin/env python3
"""Launch a pi subagent in a new herdr tab and return immediately.

Jev (TypeSafe) reads the task and picks the subagent kind, model, thinking
effort, and which skills to load. CLI flags override any of those choices.

Usage:
    subagent.py "task for the subagent" [--kind K] [--model M] [--effort E]
                [--skill NAME]... [--cwd DIR] [--workspace ID]
                [--timeout MS] [--dry-run]
    subagent.py --close TAB_ID

Creates a new tab in the calling agent's herdr workspace, starts a pi agent there,
submits the task, prints the tab id, and exits. The parent does not wait.
Close the tab later with --close.
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

KINDS = {
    "research": "You are a research subagent. Investigate and report findings. Do not modify files.",
    "implement": "You are an implementation subagent. Make the code changes the task requires.",
    "write": "You are a writing subagent. Produce the requested prose or documentation.",
}

MODELS = {
    "opencode-go/mimo-v2.6-flash": "Small, mechanical, well-specified tasks where speed matters.",
    "opencode-go/deepseek-v4.1-flash": "Most tasks; strong general coding and writing at moderate cost.",
    "openai-codex/gpt-6-luna": "Multi-step tasks that need careful reasoning.",
    "openai-codex/gpt-6-sol": "Hard, ambiguous, or high-stakes tasks.",
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
    pinned = args.kind and args.model and args.effort and args.skill is not None
    if pinned:
        profile = {
            "kind": args.kind,
            "model": args.model,
            "effort": args.effort,
            "skills": args.skill,
        }
    else:
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
        profile["kind"] = args.kind or profile["kind"]
        profile["model"] = args.model or profile["model"]
        profile["effort"] = args.effort or profile["effort"]
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


def pi_args(profile):
    args = ["--append-system-prompt", KINDS[profile["kind"]]]
    if profile["model"]:
        args += ["--model", profile["model"]]
    if profile["effort"]:
        args += ["--thinking", profile["effort"]]
    return args


def subagent_prompt(task, profile, parent_session):
    """Task prompt, prefixed with the skills to use and how to reach the parent."""
    lines = []
    if profile["skills"]:
        lines.append(f"Use these skills: {', '.join(profile['skills'])}.")
    if parent_session:
        lines.append(f"Your parent agent is intercom session {parent_session}.")
    else:
        lines.append("Find your parent agent with `intercom list`.")
    lines.append(
        "Use pi-intercom to report: when the task is finished, send your final "
        "result to the parent session with `intercom send` (fire-and-forget); "
        "when blocked on a question, `intercom ask` the parent. "
        "Reporting via intercom is mandatory, not optional. "
    )
    return "\n".join(lines) + "\n\n" + task


# --------------------------------------------------------------- main


def launch(name, pane_id, argv, timeout_ms=30000):
    """Start pi in the pane; on failure show pi's own error and report it."""

    def start(extra):
        return subprocess.run(
            [
                "herdr",
                "agent",
                "start",
                name,
                "--kind",
                "pi",
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
    # default before giving up. Only pi's error lines count; the pane echoes
    # the command line, which always contains "thinking".
    errors = [line.lower() for line in view.splitlines() if "error" in line.lower()]
    level_error = any(
        any(w in line for w in ("thinking", "reasoning", "effort")) for line in errors
    )
    if "--thinking" in argv and level_error:
        print(
            "[subagent] launch failed on effort; retrying with the model default",
            file=sys.stderr,
        )
        cut = argv.index("--thinking")
        retry = [arg for i, arg in enumerate(argv) if i not in (cut, cut + 1)]
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("task", nargs="?")
    parser.add_argument("--kind", choices=sorted(KINDS))
    parser.add_argument("--model", choices=sorted(MODELS))
    parser.add_argument("--effort", choices=sorted(EFFORTS))
    parser.add_argument("--skill", action="append")
    parser.add_argument("--cwd", default=os.getcwd())
    parser.add_argument("--workspace")
    parser.add_argument("--timeout", type=int, default=30000)
    parser.add_argument("--close", metavar="TAB_ID")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--keep", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--lines", type=int, default=40, help=argparse.SUPPRESS)
    args = parser.parse_args()

    if args.close:
        herdr("tab", "close", args.close)
        return 0
    if not args.task:
        parser.error("task is required")

    skills = discover_skills(args.cwd)
    profile = choose_profile(args, skills)

    if args.dry_run:
        print(json.dumps(profile, indent=2))
        return 0

    workspace = args.workspace or parent_workspace()
    name = f"subagent-{profile['kind']}-{os.getpid()}"
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

    if not launch(name, pane_id, pi_args(profile), timeout_ms=start_timeout):
        return 2
    parent_session = os.environ.get("PI_INTERCOM_SESSION_ID") or os.environ.get(
        "PI_SESSION_ID"
    )
    herdr("agent", "prompt", name, subagent_prompt(args.task, profile, parent_session))
    print(
        f"[subagent] launched; close with {sys.argv[0]} --close {tab_id}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

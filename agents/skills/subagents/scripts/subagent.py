#!/usr/bin/env python3
"""Launch a Subagent for one Stage of one Work Item in a new herdr tab or tmux
window, and return immediately.

The Stage decides the Subagent's skills and instructions, and pins the model
for Write and Review. Jev (TypeSafe) judges only what the Stage leaves open:
the model, and the thinking effort.

Usage:
    subagent.py --stage STAGE [--axis AXIS] --item ITEM "brief"
                [--cwd DIR] [--workspace ID | --project DIR]
                [--timeout MS] [--dry-run]
    subagent.py --stages
    subagent.py --close TAB_ID
    subagent.py --notify PANE_ID MESSAGE

Creates a new tab (herdr) or window (tmux) in the calling agent's workspace or
session, starts the agent there, submits the brief, prints the tab id, and
exits. The Manager does not wait. Close the tab later with --close. In tmux,
Subagents report back with --notify, which types MESSAGE into the Manager pane.
"""

import argparse
import json
import os
import shlex
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

# Role: (model, when Jev should pick it). A Stage may pin a role.
MODELS = {
    "builder": (
        "opencode-go/deepseek-v4.1-flash",
        "Code, research, and refactoring; the default.",
    ),
    "writer": (
        "claude-code/sonnet",
        "Prose: documentation and text for agents.",
    ),
    "critic": (
        "github-copilot/gpt-6.1-sol",
        "Review and critique; a second opinion on a hard problem.",
    ),
}

EFFORTS = {
    "minimal": "Bare minimum thinking; near-mechanical work.",
    "low": "A little thinking; simple, well-specified tasks.",
    "medium": "Moderate thinking; everyday tasks.",
    "high": "Careful thinking; multi-step tasks.",
    "xhigh": "Deep thinking; hard tasks.",
    "max": "Maximum thinking; the hardest or highest-stakes tasks.",
}

# Hard ceilings: a model listed here is never launched above this effort,
# whatever Jev asks for. Only ever lowers an effort, never raises it. Keyed by
# model name without provider, so the cap holds whichever provider serves it.
MODEL_MAX_EFFORT = {"gpt-6.1-sol": "medium", "deepseek-v4.1-flash": "high"}

# Every Stage a Subagent can run. Shape, Plan, and Ship stay with the Manager.
# "skills" are loaded in order; "model" pins a MODELS role, else Jev picks.
STAGES = {
    "research": {
        "skills": ["research"],
        "role": (
            "You run the Research stage: you are the background agent the "
            "research skill describes, so do its job yourself. Change no files "
            "except the findings file."
        ),
    },
    "design": {
        "skills": ["prototype", "codebase-design"],
        "role": (
            "You run the Design stage: build the throwaway prototype that "
            "answers the brief's design question, and report the answer."
        ),
    },
    "diagnose": {
        "skills": ["diagnosing-bugs", "coding"],
        "role": (
            "You run the Diagnose stage: find the root cause and prove it with "
            "a failing check. The fix belongs to Build unless the brief asks "
            "for it."
        ),
    },
    "build": {
        "skills": ["tdd", "coding"],
        "role": (
            "You run the Build stage: implement the brief and prove it with "
            "lint and tests scoped to what you touched. Refine and Review are "
            "later Stages run by other Subagents, so finish at your own report."
        ),
    },
    "write": {
        "skills": ["writing-for-agents"],
        "model": "writer",
        "role": "You run the Write stage: write the prose the brief asks for.",
    },
    "refine": {
        "skills": ["zero-tech-debt"],
        "role": (
            "You run the Refine stage: reshape the code this Work Item touched "
            "toward its intended design, keeping behaviour and tests green. "
            "Your scope is the diff since the brief's base, and the code it "
            "touches."
        ),
    },
    "prove": {
        "skills": [],  # the repo's verify-* skills, found at launch
        "role": (
            "You run the Prove stage: exercise the change the way a user "
            "would, and report what you observed. Change no files."
        ),
    },
    "review": {
        "model": "critic",
        "axes": {
            "standards": {
                "skills": ["review"],
                "role": (
                    "You run the Review stage, Standards axis: you are the "
                    "Standards sub-agent the review skill describes, so apply "
                    "its brief and smell baseline yourself. Change no files."
                ),
            },
            "spec": {
                "skills": ["review"],
                "role": (
                    "You run the Review stage, Spec axis: you are the Spec "
                    "sub-agent the review skill describes, so apply its brief "
                    "yourself. Change no files."
                ),
            },
            "debt": {
                "skills": ["review"],
                "role": (
                    "You run the Review stage, Debt axis: you are the Debt "
                    "sub-agent the review skill describes, so apply its brief "
                    "yourself. Change no files."
                ),
            },
        },
    },
}

SCRIPT = os.path.abspath(__file__)
STARTUP_GRACE = 3  # seconds a tmux child must survive to count as launched
# Allow slow login shells (including 35s startup) without retaining orphaned keys
# indefinitely. Only the secret-bearing env file is age-swept, never the task.
TEMP_FILE_SWEEP = 120

# Parent variables a child must inherit even though tmux spawns it from the
# server's environment; the child sources them from a 0600 temp file.
PASSTHROUGH_ENV = ["TYPESAFE_API_KEY"]

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


def project_workspace(path, mux):
    """Create or reuse the project's session/workspace without focusing it.

    nexo prints the container it opened; its id is a tmux session id or a herdr
    workspace_id, which is exactly what --workspace expects.
    """
    cmd = ["nexo", "--json", f"--backend={mux}", "open", "--no-focus", path]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"nexo open failed for {path}: {result.stderr.strip()}")
    container = json.loads(result.stdout)
    print(
        f"[subagent] project {container['name']} ({container['id']})"
        f"{' created' if container.get('created') else ''}",
        file=sys.stderr,
    )
    return container["id"]


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


def child_env_file(path=None):
    """0600 temp file exporting allowlisted parent variables for a child."""
    if path is None:
        fd, path = tempfile.mkstemp(prefix="subagent-env-")
    else:
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
    """Installed skills by name: global ones, the repo's from cwd upward, then
    the main checkout's, whose untracked skills a fresh worktree lacks."""
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
        if parent == current or os.path.exists(os.path.join(current, ".git")):
            break
        current = parent
    main = main_checkout(cwd)
    if main:
        roots.append(os.path.join(main, ".pi/skills"))
        roots.append(os.path.join(main, ".agents/skills"))

    skills = {}
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root, followlinks=True):
            if "SKILL.md" not in filenames:
                continue
            name, _ = read_frontmatter(os.path.join(dirpath, "SKILL.md"))
            if name and name not in skills:
                skills[name] = dirpath
            dirnames[:] = []  # a skill directory contains no nested skills
    return skills


def stage_spec(stage, axis):
    """The Stage's skills, role text, and pinned MODELS role (or None)."""
    spec = STAGES[stage]
    if "axes" in spec:
        if axis not in spec["axes"]:
            sys.exit(f"--stage {stage} needs --axis {{{','.join(spec['axes'])}}}")
        return {**spec["axes"][axis], "model": spec.get("model")}
    if axis:
        sys.exit(f"--stage {stage} takes no --axis")
    return {**spec, "model": spec.get("model")}


def stage_skills(stage, spec, cwd):
    """Skills to load as {name: SKILL.md path}, failing fast when one is not
    installed for cwd."""
    installed = discover_skills(cwd)
    skills = list(spec["skills"])
    if stage == "prove":
        skills = sorted(name for name in installed if name.startswith("verify-"))
        if not skills:
            sys.exit(
                "no verify-* skill for this repo; create one with "
                "create-verification-skill, or Prove without a Subagent"
            )
    missing = [name for name in skills if name not in installed]
    if missing:
        sys.exit(f"skills not installed for {cwd}: {', '.join(missing)}")
    return {name: os.path.join(installed[name], "SKILL.md") for name in skills}


def print_stages():
    for stage, spec in STAGES.items():
        pinned = spec.get("model")
        model = f"{pinned}: {MODELS[pinned][0]}" if pinned else "Jev"
        axes = spec.get("axes") or {None: spec}
        for axis, axis_spec in axes.items():
            label = f"{stage} --axis {axis}" if axis else stage
            skills = ", ".join(axis_spec["skills"]) or "the repo's verify-* skills"
            print(f"{label:<24} model {model:<40} skills {skills}")
    return 0


# --------------------------------------------------------------- reports


def git_common_dir(cwd):
    proc = subprocess.run(
        ["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"],
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.stdout.strip() if proc.returncode == 0 else None


def main_checkout(cwd):
    """Root of the main checkout, also when cwd is a worktree; None outside git."""
    common = git_common_dir(cwd)
    return os.path.dirname(common) if common else None


def report_path(cwd, item, stage, axis, create=True):
    """Where the Subagent writes its report, in the main checkout's .agents/.

    Worktrees share the main checkout's reports, so the Manager reads every
    Stage's report from one place. The reports and the Ledger are kept out of
    git through info/exclude, leaving any tracked .agents/skills alone.
    """
    common = git_common_dir(cwd)
    root = os.path.dirname(common) if common else os.path.abspath(cwd)
    reports = os.path.join(root, ".agents", "reports")
    if create:
        os.makedirs(reports, exist_ok=True)
    if create and common:
        exclude = os.path.join(common, "info", "exclude")
        wanted = ["/.agents/ledger.md", "/.agents/reports/"]
        try:
            with open(exclude, encoding="utf-8") as handle:
                present = handle.read().splitlines()
        except OSError:
            present = []
        lines = [line for line in wanted if line not in present]
        if lines:
            os.makedirs(os.path.dirname(exclude), exist_ok=True)
            with open(exclude, "a", encoding="utf-8") as handle:
                handle.write("".join(f"{line}\n" for line in lines))
    name = "-".join(part for part in (item, stage, axis) if part)
    return os.path.join(reports, f"{name}.md")


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


def jev_profile(brief, stage, pinned):
    """Ask Jev for whatever the Stage leaves open: effort, and the model if unpinned."""
    questions = {
        "effort": {
            "type": "choice",
            "instructions": f"Which thinking effort does this {stage} stage need?",
            "criteria": EFFORTS,
        },
    }
    if not pinned:
        criteria = {}
        for role, (model_id, when) in MODELS.items():
            levels = model_thinking_levels(model_id)
            criteria[role] = f"{when} (thinking: {', '.join(levels)})" if levels else when
        questions["model"] = {
            "type": "choice",
            "instructions": f"Which model should run this {stage} stage, given its difficulty?",
            "criteria": criteria,
        }
    answers = jev(f"Stage: {stage}\n\n{brief}", questions)
    return {
        "model": pinned or answers["model"]["choice"],
        "effort": answers["effort"]["choice"],
    }


def choose_profile(args, spec):
    pinned = spec["model"]
    try:
        profile = jev_profile(args.task, args.stage, pinned)
    except (urllib.error.URLError, KeyError, ValueError, RuntimeError) as err:
        print(
            f"[subagent] jev unavailable ({err}); using the model's default effort",
            file=sys.stderr,
        )
        profile = {"model": pinned or "builder", "effort": None}

    role = profile["model"] if profile["model"] in MODELS else "builder"
    profile["model"] = MODELS[role][0]
    profile["effort"] = profile["effort"] if profile["effort"] in EFFORTS else None

    # Some models must never be launched above their ceiling, whatever Jev asks.
    cap = MODEL_MAX_EFFORT.get(profile["model"].partition("/")[2])
    if cap and profile["effort"]:
        if THINKING_ORDER.index(profile["effort"]) > THINKING_ORDER.index(cap):
            print(
                f"[subagent] {profile['model']} is capped at {cap} effort; "
                f"using {cap}",
                file=sys.stderr,
            )
            profile["effort"] = cap

    # A model may not offer every level; clamp to the nearest one it supports
    # instead of letting pi silently adjust (or fail on) the launch.
    if profile["effort"]:
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


def claude_args(profile, report, mux="herdr"):
    args = ["--append-system-prompt", profile["role"]]
    if profile["model"]:
        args += ["--model", profile["model"].partition("/")[2]]
    if profile["effort"]:
        args += ["--effort", clamp_effort(profile["effort"], CLAUDE_EFFORTS)]
    # Let reports to the Manager run without a permission prompt, or they
    # stall. Edit rules take absolute paths with a leading "//".
    send = "herdr agent prompt" if mux == "herdr" else f"{SCRIPT} --notify"
    args += ["--allowedTools", f"Bash({send} *)", f"Edit(/{report})"]
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
    args = ["--append-system-prompt", profile["role"]]
    if profile["model"]:
        args += ["--model", profile["model"]]
    if profile["effort"]:
        args += ["--thinking", profile["effort"]]
    return args


# What every Subagent is told, whichever way it reports.
SUBAGENT_RULES = (
    "The Manager runs the workflow; you run this one Stage and report. Send "
    "the Manager two kinds of message only: the completion report, and "
    "questions. A decision the brief leaves open (a proposal, a choice "
    "between approaches) is a question: ask it and wait for the answer. "
    "After you report, a new prompt from the Manager is a follow-up: apply "
    "it, update your report file, and report again. Delegating belongs to "
    "the Manager, so do every part of this Stage yourself."
)


def pane_lines(manager_pane, tag, mux="herdr"):
    """How a Subagent reaches the Manager without intercom: typing into its pane."""
    target = manager_pane or "<manager-pane-id>"
    send = "herdr agent prompt" if mux == "herdr" else f"{SCRIPT} --notify"
    lines = []
    if not manager_pane:
        lines.append("Find the Manager's pane id with `herdr agent list`.")
    lines += [
        f"The Manager runs in {mux} pane {target}. Reach it by prompting its "
        "pane through Bash:",
        "",
        "```sh",
        f'{send} {target} "[{tag}] TASK COMPLETE: <one-line summary>"',
        f'{send} {target} "[{tag}] QUESTION: <question>"',
        "```",
        "",
        "When the Stage is finished, send the completion report that way. "
        "When blocked on a question, send it, then end your turn; the "
        "Manager's answer arrives as your next prompt. Always start the "
        f"message with `[{tag}]`.",
    ]
    if mux == "herdr":
        lines[-1] += (
            " If herdr rejects the prompt (for example `agent_blocked`), wait "
            "a few seconds and retry."
        )
    lines[-1] += " Reporting this way is mandatory, not optional."
    return lines


def subagent_prompt(brief, profile, manager_session, tag, report, manager_pane=None, mux="herdr"):
    """Brief, prefixed with the Stage, its skills, the report file, and how to reach the Manager."""
    lines = [f"You are {tag}."]
    if profile["skills"]:
        lines.append("Read and follow these skills:")
        lines += [f"- {name}: {path}" for name, path in profile["skills"].items()]
    lines.append(
        f"Write your full report to {report}: what you did, how you proved "
        "it, and anything left open. The completion report is one line "
        "pointing at it."
    )
    # Intercom only works between two pi agents. A Claude Subagent has no
    # intercom tool, and a Manager without an intercom session (e.g. Claude)
    # never receives intercom messages, so everything else reports through
    # its pane.
    if is_claude(profile) or not manager_session:
        lines += pane_lines(manager_pane, tag, mux)
    else:
        lines.append(f"The Manager is intercom session {manager_session}.")
        lines.append(
            "Use pi-intercom to report: when the Stage is finished, send the "
            "completion report to the Manager with `intercom send` "
            "(fire-and-forget); when blocked on a question, `intercom ask` "
            f"the Manager. Start every message with `[{tag}]`. Reporting via "
            "intercom is mandatory, not optional."
        )
    lines += ["", SUBAGENT_RULES]
    return "\n".join(lines) + "\n\n" + brief


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
    """Start the agent in the pane; on failure show its own error and report it.

    GAP: herdr children were not testable here because HERDR_ENV is unset.
    Whether a herdr child receives PASSTHROUGH_ENV is unverified.
    """

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
    over-long commands. A login shell is not enough for the environment (zsh
    reads ~/.zprofile, not ~/.profile), so PASSTHROUGH_ENV travels in a second
    0600 temp file the child sources and deletes before exec. A detached
    sweeper removes only the env file after TEMP_FILE_SWEEP seconds as a
    backstop, registered before respawn so parent death cannot bypass it. The
    task is never age-swept. The pane remains after the agent exits, so a failed
    launch stays visible.
    """
    tmux("set-option", "-w", "-t", pane_id, "remain-on-exit", "on")
    shell = os.environ.get("SHELL", "/bin/sh")
    script = (
        'if ! prompt=$(cat "$1"); then '
        'printf "%s\\n" "[subagent] cannot read prompt file: $1" >&2; '
        'rm -f "$1" "$2"; exit 1; fi; '
        'rm -f "$1"; if [ -r "$2" ]; then . "$2"; fi; rm -f "$2"; '
        'shift 2; exec "$@" "$prompt"'
    )

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
                shell, "-lc", script, name, path, env_path, kind, *extra, "--",
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
    parser.add_argument("task", nargs="?", metavar="brief")
    parser.add_argument("--stage", choices=STAGES)
    parser.add_argument("--axis")
    parser.add_argument("--item", help="Work Item id, as in the Ledger")
    parser.add_argument("--stages", action="store_true", help="print the Stage table")
    parser.add_argument("--cwd")
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--workspace")
    target.add_argument("--project", metavar="DIR")
    parser.add_argument("--timeout", type=int, default=30000)
    parser.add_argument("--close", metavar="TAB_ID")
    parser.add_argument("--notify", nargs=2, metavar=("PANE_ID", "MESSAGE"))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--keep", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--lines", type=int, default=40, help=argparse.SUPPRESS)
    args = parser.parse_args()

    if args.stages:
        return print_stages()
    if args.notify:
        tmux_notify(*args.notify)
        return 0
    if args.close:
        if multiplexer() == "herdr":
            herdr("tab", "close", args.close)
        else:
            tmux("kill-window", "-t", args.close)
        return 0
    if not (args.task and args.stage and args.item):
        parser.error("a brief, --stage, and --item are required")
    if args.project:
        args.project = os.path.abspath(os.path.expanduser(args.project))
    args.cwd = args.cwd or args.project or os.getcwd()

    spec = stage_spec(args.stage, args.axis)
    skills = stage_skills(args.stage, spec, args.cwd)
    profile = choose_profile(args, spec)
    profile.update(skills=skills, role=spec["role"])
    report = report_path(
        args.cwd, args.item, args.stage, args.axis, create=not args.dry_run
    )
    stage = f"{args.stage} {args.axis}" if args.axis else args.stage
    name = f"subagent-{args.stage}-{os.getpid()}"
    tag = f"{name} · {args.item} · {stage}"

    if args.dry_run:
        print(json.dumps({**profile, "name": name, "report": report}, indent=2))
        return 0

    mux = multiplexer()
    if args.project:
        args.workspace = project_workspace(args.project, mux)
    if is_claude(profile):
        trust_claude_dir(args.cwd)
        kind, argv = "claude", claude_args(profile, report, mux)
    else:
        kind, argv = "pi", pi_args(profile)
    manager_session = os.environ.get("PI_INTERCOM_SESSION_ID") or os.environ.get(
        "PI_SESSION_ID"
    )
    manager_pane = os.environ.get("HERDR_PANE_ID" if mux == "herdr" else "TMUX_PANE")
    prompt = subagent_prompt(
        args.task, profile, manager_session, tag, report, manager_pane, mux
    )

    if mux == "tmux":
        session = args.workspace or tmux_session()
        tab_id, pane_id = tmux(
            "new-window", "-d", "-P", "-F", "#{window_id} #{pane_id}",
            "-t", f"{session}:", "-c", args.cwd, "-n", name,
        ).split()
        print(
            f"[subagent] {name} window {tab_id} pane {pane_id} model {profile['model']} effort {profile['effort']}",
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
            f"[subagent] {name} tab {tab_id} pane {pane_id} model {profile['model']} effort {profile['effort']}",
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

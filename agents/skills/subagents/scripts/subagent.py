#!/usr/bin/env python3
"""Prepare one Stage of one Work Item for a Subagent and print its launch spec.

The Stage decides the Subagent's skills and instructions, and pins the model
for Write and Review. Jev (TypeSafe) judges only what the Stage leaves open:
the model, and the thinking effort.

This script never touches a session host. It prints one JSON launch spec on
stdout; the Markdown extension named by --extension says how the host in use
launches, addresses, and closes the Subagent.

Usage:
    subagent.py --stages

    subagent.py --stage STAGE [--axis AXIS] --item ITEM --extension FILE
                --manager ADDRESS [--cwd DIR] [--dry-run] "brief"

A dry run prints the same spec without creating the report directory or
editing .git/info/exclude.
"""

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

# Role: (model, when Jev should pick it). A Stage may pin a role.
MODELS = {
    "builder": (
        "claude-code/claude-haiku-5-5",
        "Code, research, and refactoring; the default.",
    ),
    "writer": (
        "claude-code/claude-haiku-5-5",
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
MODEL_MAX_EFFORT = {"gpt-6.1-sol": "medium"}

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


# --------------------------------------------------------- engine helpers


def is_claude(profile):
    return (profile["model"] or "").partition("/")[0] == CLAUDE_PROVIDER


def engine_spec(profile):
    """The engine and its argv for a profile: no session host is assumed.

    The role travels as a system prompt here. A host without such a flag
    (Paseo) inlines the spec's role instead.
    """
    role = profile["role"]
    if is_claude(profile):
        argv = ["--append-system-prompt", role]
        if profile["model"]:
            argv += ["--model", profile["model"].partition("/")[2]]
        if profile["effort"]:
            argv += ["--effort", clamp_effort(profile["effort"], CLAUDE_EFFORTS)]
        return {"kind": "claude", "argv": argv}
    argv = ["--append-system-prompt", role]
    if profile["model"]:
        argv += ["--model", profile["model"]]
    if profile["effort"]:
        argv += ["--thinking", profile["effort"]]
    return {"kind": "pi", "argv": argv}


# --------------------------------------------------------------- skills


def read_frontmatter(path):
    """(name, description, model_invocable) from a SKILL.md.

    model_invocable is False when the frontmatter opts the skill out of model
    invocation with `disable-model-invocation: true`, so a Subagent cannot
    load it.
    """
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read(8192)
    except OSError:
        return None, None, True
    if not text.startswith("---"):
        return None, None, True
    end = text.find("\n---", 3)
    if end == -1:
        return None, None, True

    name = description = None
    model_invocable = True
    lines = text[3:end].splitlines()
    for index, line in enumerate(lines):
        if line.startswith("name:"):
            name = line.split(":", 1)[1].strip().strip("\"'")
        elif line.startswith("disable-model-invocation:"):
            value = line.split(":", 1)[1].strip()
            if value[:1] not in ("'", '"'):
                value = value.split(" #", 1)[0].strip()
            model_invocable = value.strip("\"'").lower() != "true"
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
    return name, description, model_invocable


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
            name, *_ = read_frontmatter(os.path.join(dirpath, "SKILL.md"))
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
    unloadable = [
        name
        for name in skills
        if not read_frontmatter(os.path.join(installed[name], "SKILL.md"))[2]
    ]
    if unloadable:
        sys.exit(
            "skills a Subagent cannot load (disable-model-invocation: true): "
            f"{', '.join(unloadable)}"
        )
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


def choose_profile(brief, stage, pinned):
    """The model and effort a Stage runs with, capped and clamped to what exists."""
    try:
        profile = jev_profile(brief, stage, pinned)
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


# --------------------------------------------------------------- prompt


# What every Subagent is told, whichever host it runs on.
SUBAGENT_RULES = (
    "The Manager runs the workflow; you run this one Stage and report. Send "
    "the Manager two kinds of message only: the completion report, and "
    "questions. A decision the brief leaves open (a proposal, a choice "
    "between approaches) is a question: ask it and wait for the answer. "
    "After you report, a new prompt from the Manager is a follow-up: apply "
    "it, update your report file, and report again. Delegating belongs to "
    "the Manager, so do every part of this Stage yourself."
)


def subagent_prompt(brief, role, skills, report, extension, manager, tag):
    """The brief, prefixed with the Stage role, skills, report, and how to report.

    The Stage role travels inside the prompt as well as in engine.argv, so a
    host whose own CLI has no append-system-prompt flag still delivers it.
    The host commands themselves live in the extension file, not here.
    """
    lines = [role, "", f"You are {tag}."]
    if skills:
        lines.append("Read and follow these skills:")
        lines += [f"- {name}: {path}" for name, path in skills.items()]
    lines.append(
        f"Write your full report to {report}: what you did, how you proved "
        "it, and anything left open. The completion report is one line "
        "pointing at it."
    )
    lines.append(
        f"Before starting the Stage, read and follow {extension}: it explains "
        "how to reach the Manager, ask Questions, and send the Completion "
        f"report. The Manager's address is {manager}. Check that its reporting "
        "route is usable from this machine and agrees with the launch context. "
        "The Manager may be on another machine; never infer the Manager from "
        "local environment variables or substitute a local session. If the "
        "route is missing, unusable, or conflicting, stop and ask for a "
        "corrected route in this conversation before doing any Stage work "
        "or sending to another session. Reporting through the confirmed route "
        "is mandatory."
    )
    lines += ["", SUBAGENT_RULES]
    return "\n".join(lines) + "\n\n" + brief


def launch_spec(brief, stage, axis, item, cwd, extension, manager, profile):
    """The one JSON object every host extension consumes."""
    stage_label = f"{stage} {axis}" if axis else stage
    name = f"subagent-{stage}-{os.getpid()}"
    tag = f"{name} · {item} · {stage_label}"
    engine = engine_spec(profile)
    return {
        "item": item,
        "stage": stage,
        "axis": axis,
        "name": name,
        "tag": tag,
        "cwd": cwd,
        "report": profile["report"],
        "extension": extension,
        "manager": manager,
        "model": profile["model"],
        "effort": profile["effort"],
        "role": profile["role"],
        "skills": profile["skills"],
        "engine": engine,
        "prompt": subagent_prompt(
            brief,
            profile["role"],
            profile["skills"],
            profile["report"],
            extension,
            manager,
            tag,
        ),
    }


# --------------------------------------------------------------- main


def parse_args(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("brief", nargs="?", metavar="brief")
    parser.add_argument("--stage", choices=STAGES)
    parser.add_argument("--axis")
    parser.add_argument("--item", help="Work Item id, as in the Ledger")
    parser.add_argument("--stages", action="store_true", help="print the Stage table")
    parser.add_argument("--cwd")
    parser.add_argument(
        "--extension",
        metavar="FILE",
        help="Markdown file explaining how this host launches and reports",
    )
    parser.add_argument("--manager", help="the Manager's native address on its host")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    if args.stages:
        return args
    if not (args.brief and args.stage and args.item):
        parser.error("a brief, --stage, and --item are required")
    if not args.extension:
        parser.error("--extension FILE is required")
    if not args.manager or not args.manager.strip():
        parser.error("--manager ADDRESS is required; use the Manager's native host address")
    return args


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.stages:
        return print_stages()

    extension = os.path.abspath(os.path.expanduser(args.extension))
    if not os.path.isfile(extension):
        sys.exit(f"extension file not found: {args.extension}")
    args.cwd = os.path.abspath(os.path.expanduser(args.cwd or os.getcwd()))
    if not os.path.isdir(args.cwd):
        sys.exit(f"cwd is not a directory: {args.cwd}")

    spec = stage_spec(args.stage, args.axis)
    skills = stage_skills(args.stage, spec, args.cwd)
    profile = choose_profile(args.brief, args.stage, spec["model"])
    profile.update(skills=skills, role=spec["role"])
    profile["report"] = report_path(
        args.cwd, args.item, args.stage, args.axis, create=not args.dry_run
    )
    print(
        json.dumps(
            launch_spec(
                args.brief,
                args.stage,
                args.axis,
                args.item,
                args.cwd,
                extension,
                args.manager,
                profile,
            ),
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

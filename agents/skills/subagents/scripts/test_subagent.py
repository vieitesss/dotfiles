#!/usr/bin/env python3
"""Regression tests for subagent.py's launcher.

Every test runs offline and launches nothing: Jev is stubbed, HOME points at a
temp dir, and no multiplexer is ever resolved for the dry-run path.
"""

import argparse
import contextlib
import io
import json
import os
import subprocess
import tempfile
import unittest
from unittest import mock

import subagent


def write_skill(repo, name, frontmatter=""):
    """Install a minimal skill into repo's tracked .agents/skills."""
    directory = os.path.join(repo, ".agents", "skills", name)
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, "SKILL.md"), "w", encoding="utf-8") as handle:
        handle.write(
            f"---\nname: {name}\ndescription: a test skill\n{frontmatter}---\nbody\n"
        )


class TempRepoTest(unittest.TestCase):
    """A throwaway HOME and a git repo to run the launcher against."""

    def setUp(self):
        base = tempfile.TemporaryDirectory()
        self.addCleanup(base.cleanup)
        self.repo = os.path.join(base.name, "repo")
        os.makedirs(self.repo)
        subprocess.run(
            ["git", "-C", self.repo, "init", "-q"], check=True, capture_output=True
        )
        env = mock.patch.dict(os.environ, {"HOME": os.path.join(base.name, "home")})
        env.start()
        self.addCleanup(env.stop)

    def exclude(self):
        path = os.path.join(self.repo, ".git", "info", "exclude")
        with open(path, encoding="utf-8") as handle:
            return handle.read()


class EffortCapTest(TempRepoTest):
    """The effort ceiling is keyed by model name, so the same model is capped
    on every provider (regression: it used to be keyed provider/model, so the
    cap stopped applying when a model moved provider, and the deepseek cap
    never applied at all)."""

    def choose(self, model_id, effort):
        args = argparse.Namespace(task="do the thing", stage="build")
        answers = {"effort": {"choice": effort}, "model": {"choice": "builder"}}
        with mock.patch.object(subagent, "jev", return_value=answers):
            with mock.patch.dict(subagent.MODELS, {"builder": (model_id, "test")}):
                with contextlib.redirect_stderr(io.StringIO()):
                    return subagent.choose_profile(args, {"model": None})

    def test_the_cap_holds_for_the_same_model_on_any_provider(self):
        for provider in ("opencode-go", "another-provider"):
            with self.subTest(provider=provider):
                profile = self.choose(f"{provider}/deepseek-v4.1-flash", "max")
                self.assertEqual(profile["effort"], "high")

    def test_the_cap_only_ever_lowers_an_effort(self):
        profile = self.choose("opencode-go/deepseek-v4.1-flash", "low")
        self.assertEqual(profile["effort"], "low")
        profile = self.choose("opencode-go/some-uncapped-model", "max")
        self.assertEqual(profile["effort"], "max")


class DryRunTest(TempRepoTest):
    def test_dry_run_creates_no_dot_agents_and_edits_no_git_exclude(self):
        write_skill(self.repo, "tdd")
        write_skill(self.repo, "coding")
        exclude_before = self.exclude()
        argv = [
            "subagent.py", "--stage", "build", "--item", "wi-1",
            "--cwd", self.repo, "--dry-run", "do the thing",
        ]
        answers = {"effort": {"choice": "medium"}, "model": {"choice": "builder"}}
        stdout = io.StringIO()
        with mock.patch.object(subagent, "jev", return_value=answers):
            with mock.patch.object(
                subagent, "multiplexer",
                side_effect=AssertionError("a dry run must not pick a multiplexer"),
            ):
                with mock.patch("sys.argv", argv):
                    with contextlib.redirect_stdout(stdout):
                        with contextlib.redirect_stderr(io.StringIO()):
                            self.assertEqual(subagent.main(), 0)

        profile = json.loads(stdout.getvalue())
        reports = os.path.join(os.path.realpath(self.repo), ".agents", "reports")
        self.assertEqual(profile["report"], os.path.join(reports, "wi-1-build.md"))
        self.assertFalse(os.path.exists(reports))
        self.assertFalse(os.path.exists(os.path.join(self.repo, ".agents", "ledger.md")))
        self.assertEqual(self.exclude(), exclude_before)
        self.assertNotIn("/.agents/reports/", self.exclude())


class StageSkillsTest(TempRepoTest):
    def test_stage_skills_rejects_a_skill_it_could_not_auto_load(self):
        write_skill(self.repo, "visible")
        write_skill(self.repo, "hidden", "disable-model-invocation: true\n")

        skill = os.path.join(self.repo, ".agents", "skills", "visible", "SKILL.md")
        self.assertEqual(
            subagent.stage_skills("build", {"skills": ["visible"]}, self.repo),
            {"visible": skill},
        )
        with self.assertRaises(SystemExit) as caught:
            subagent.stage_skills("build", {"skills": ["visible", "hidden"]}, self.repo)
        self.assertIn("hidden", str(caught.exception))

    def test_stage_skills_rejects_a_disabled_skill_with_an_inline_comment(self):
        write_skill(self.repo, "visible")
        write_skill(self.repo, "hidden", "disable-model-invocation: true # user-only\n")

        with self.assertRaises(SystemExit) as caught:
            subagent.stage_skills("build", {"skills": ["visible", "hidden"]}, self.repo)
        self.assertIn("hidden", str(caught.exception))


if __name__ == "__main__":
    unittest.main()

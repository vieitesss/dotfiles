#!/usr/bin/env python3
"""Regression tests for subagent.py's Stage preparation.

Every test runs offline and launches nothing: Jev is stubbed, HOME points at a
temp dir, and no session host is ever resolved.
"""

import contextlib
import io
import os
import subprocess
import tempfile
import unittest
from unittest import mock

import subagent
from test_support import prepare_spec


def write_skill(repo, name, frontmatter=""):
    """Install a minimal skill into repo's tracked .agents/skills."""
    directory = os.path.join(repo, ".agents", "skills", name)
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, "SKILL.md"), "w", encoding="utf-8") as handle:
        handle.write(
            f"---\nname: {name}\ndescription: a test skill\n{frontmatter}---\nbody\n"
        )


class TempRepoTest(unittest.TestCase):
    """A throwaway HOME and a git repo to run preparation against."""

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

    def extension(self, directory=None):
        """A minimal Markdown extension fixture; returns its absolute path."""
        directory = directory or self.repo
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, "fixture-extension.md")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("# fixture host\n")
        return path

    def prepare(self, *extra, brief="do the thing", cwd=None):
        """Run main() and return the parsed launch spec."""
        argv = [
            "subagent.py", "--stage", "build", "--item", "wi-1",
            "--cwd", cwd or self.repo,
            "--extension", self.extension(), "--manager", "addr-42",
            *extra, brief,
        ]
        return prepare_spec(argv)


class DryRunTest(TempRepoTest):
    def test_dry_run_creates_no_dot_agents_and_edits_no_git_exclude(self):
        write_skill(self.repo, "tdd")
        write_skill(self.repo, "coding")
        exclude_before = self.exclude()
        spec = self.prepare("--dry-run")

        reports = os.path.join(os.path.realpath(self.repo), ".agents", "reports")
        self.assertEqual(spec["report"], os.path.join(reports, "wi-1-build.md"))
        self.assertFalse(os.path.exists(reports))
        self.assertFalse(
            os.path.exists(os.path.join(self.repo, ".agents", "ledger.md"))
        )
        self.assertEqual(self.exclude(), exclude_before)
        self.assertNotIn("/.agents/reports/", self.exclude())
        # Preparation never pre-accepts Claude Code's trust dialog.
        self.assertFalse(os.path.exists(os.path.expanduser("~/.claude.json")))

    def test_preparation_without_dry_run_creates_reports_and_excludes(self):
        write_skill(self.repo, "tdd")
        write_skill(self.repo, "coding")
        spec = self.prepare()

        self.assertTrue(os.path.isdir(os.path.dirname(spec["report"])))
        self.assertIn("/.agents/reports/", self.exclude())
        self.assertFalse(os.path.exists(os.path.expanduser("~/.claude.json")))


class PreparedSpecTest(TempRepoTest):
    def setUp(self):
        super().setUp()
        write_skill(self.repo, "tdd")
        write_skill(self.repo, "coding")
        self.spec = self.prepare("--dry-run", "--manager", "addr-42")

    def test_spec_carries_identity_extension_and_manager(self):
        self.assertEqual(self.spec["item"], "wi-1")
        self.assertEqual(self.spec["stage"], "build")
        self.assertIsNone(self.spec["axis"])
        self.assertEqual(self.spec["manager"], "addr-42")
        self.assertEqual(self.spec["extension"], self.extension())
        self.assertTrue(os.path.isabs(self.spec["extension"]))
        self.assertTrue(self.spec["tag"].startswith(self.spec["name"]))
        self.assertIn("wi-1", self.spec["tag"])

    def test_prompt_reaches_the_subagent_with_role_skills_report_and_contact(self):
        prompt = self.spec["prompt"]
        self.assertIn(self.spec["role"], prompt)
        self.assertIn(self.spec["name"], prompt)
        self.assertIn(self.spec["report"], prompt)
        self.assertIn(self.spec["extension"], prompt)
        self.assertIn("addr-42", prompt)
        self.assertIn("tdd", prompt)
        self.assertIn("coding", prompt)
        self.assertIn(subagent.SUBAGENT_RULES, prompt)
        self.assertIn("do the thing", prompt)

    def test_prompt_checks_the_reporting_route_before_starting_the_stage(self):
        prompt = self.spec["prompt"]
        self.assertIn("Before starting the Stage", prompt)
        self.assertIn("usable from this machine", prompt)
        self.assertIn("stop and ask", prompt)
        self.assertIn("this conversation", prompt)
        self.assertIn("never infer the Manager from local", prompt)

    def test_prompt_carries_no_host_commands(self):
        prompt = self.spec["prompt"]
        for forbidden in ("intercom", "--notify", "paseo", "herdr agent"):
            self.assertNotIn(forbidden, prompt)

    def test_spec_has_no_multiplexer_keys(self):
        self.assertNotIn("workspace", self.spec)
        self.assertNotIn("notify", self.spec)
        self.assertNotIn("mux", self.spec)

    def test_the_prompt_carries_the_role_without_rereading_engine_argv(self):
        self.assertEqual(self.spec["engine"]["kind"], "claude")
        self.assertNotIn("kind", self.spec)
        self.assertTrue(self.spec["prompt"].startswith(self.spec["role"]))


class ExtensionPointerTest(TempRepoTest):
    def run_main(self, extension, *extra):
        argv = [
            "subagent.py", "--stage", "build", "--item", "wi-1",
            "--cwd", self.repo, "--extension", extension, "--dry-run",
            "--manager", "addr-42", *extra, "brief",
        ]
        with mock.patch("sys.argv", argv):
            with contextlib.redirect_stderr(io.StringIO()):
                subagent.main()

    def test_missing_extension_option_is_refused(self):
        write_skill(self.repo, "tdd")
        write_skill(self.repo, "coding")
        argv = [
            "subagent.py", "--stage", "build", "--item", "wi-1",
            "--cwd", self.repo, "--dry-run", "brief",
        ]
        stderr = io.StringIO()
        with mock.patch("sys.argv", argv):
            with contextlib.redirect_stderr(stderr):
                with self.assertRaises(SystemExit) as caught:
                    subagent.main()
        self.assertEqual(caught.exception.code, 2)
        self.assertIn("--extension", stderr.getvalue())

    def test_missing_manager_is_refused_before_preparation(self):
        extension = self.extension()
        stderr = io.StringIO()
        with mock.patch.object(subagent, "stage_skills", return_value={}) as skills:
            with mock.patch.object(subagent, "choose_profile", return_value={
                "model": "claude-code/sonnet", "effort": "low",
            }):
                with contextlib.redirect_stdout(io.StringIO()):
                    with contextlib.redirect_stderr(stderr):
                        with self.assertRaises(SystemExit) as caught:
                            subagent.main([
                                "--stage", "build", "--item", "wi-1",
                                "--cwd", self.repo, "--extension", extension, "brief",
                            ])
        self.assertEqual(caught.exception.code, 2)
        self.assertIn("--manager", stderr.getvalue())
        skills.assert_not_called()
        self.assertFalse(os.path.exists(os.path.join(self.repo, ".agents")))

    def test_empty_manager_is_refused(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as caught:
                self.run_main(self.extension(), "--manager", "")
        self.assertEqual(caught.exception.code, 2)

    def test_nonexistent_extension_is_refused(self):
        write_skill(self.repo, "tdd")
        write_skill(self.repo, "coding")
        path = os.path.join(self.repo, "nope.md")
        with self.assertRaises(SystemExit) as caught:
            self.run_main(path)
        self.assertIn("extension file not found", str(caught.exception))

    def test_directory_extension_is_refused(self):
        write_skill(self.repo, "tdd")
        write_skill(self.repo, "coding")
        with self.assertRaises(SystemExit) as caught:
            self.run_main(self.repo)
        self.assertIn("extension file not found", str(caught.exception))

    def test_an_external_extension_fixture_needs_no_core_change(self):
        write_skill(self.repo, "tdd")
        write_skill(self.repo, "coding")
        with tempfile.TemporaryDirectory() as elsewhere:
            extension = self.extension(elsewhere)
            argv = [
                "subagent.py", "--stage", "build", "--item", "wi-1",
                "--cwd", self.repo, "--extension", extension, "--dry-run",
                "--manager", "addr-42", "brief",
            ]
            spec = prepare_spec(argv)
            self.assertEqual(spec["extension"], extension)
            self.assertIn(extension, spec["prompt"])


class SpacesInPathsTest(TempRepoTest):
    def test_paths_with_spaces_reach_the_spec_whole(self):
        spaced = os.path.join(os.path.dirname(self.repo), "re po")
        os.makedirs(spaced)
        for name in ("tdd", "coding"):
            write_skill(spaced, name)
        extension = self.extension(os.path.join(spaced, "ex ten"))
        argv = [
            "subagent.py", "--stage", "build", "--item", "wi-1", "--cwd", spaced,
            "--extension", extension, "--manager", "add ress", "--dry-run",
            "do the thing",
        ]
        spec = prepare_spec(argv)
        self.assertEqual(spec["cwd"], spaced)
        self.assertIn("re po/.agents/reports/wi-1-build.md", spec["report"])
        self.assertIn(extension, spec["prompt"])
        self.assertIn("add ress", spec["prompt"])
        self.assertNotIn("None", spec["prompt"])


class StageAxisTest(TempRepoTest):
    def test_review_needs_an_axis(self):
        with self.assertRaises(SystemExit) as caught:
            subagent.stage_spec("review", None)
        self.assertIn("--axis", str(caught.exception))

    def test_unknown_review_axis_is_refused(self):
        with self.assertRaises(SystemExit) as caught:
            subagent.stage_spec("review", "vibes")
        self.assertIn("--axis", str(caught.exception))

    def test_axis_on_a_stage_without_axes_is_refused(self):
        with self.assertRaises(SystemExit) as caught:
            subagent.stage_spec("build", "spec")
        self.assertIn("takes no --axis", str(caught.exception))

    def test_review_axis_selects_its_role_and_skills(self):
        spec = subagent.stage_spec("review", "debt")
        self.assertIn("Debt axis", spec["role"])
        self.assertEqual(spec["skills"], ["review"])
        self.assertEqual(spec["model"], "critic")


class EngineSpecTest(TempRepoTest):
    def test_pi_engine_receives_model_and_thinking(self):
        profile = {
            "role": "role text",
            "model": "opencode-go/deepseek-v4.1-flash",
            "effort": "high",
        }
        engine = subagent.engine_spec(profile)
        self.assertEqual(engine["kind"], "pi")
        self.assertEqual(
            engine["argv"],
            [
                "--append-system-prompt", "role text",
                "--model", "opencode-go/deepseek-v4.1-flash",
                "--thinking", "high",
            ],
        )

    def test_claude_engine_drops_the_provider_and_clamps_effort(self):
        profile = {
            "role": "prose role",
            "model": "claude-code/sonnet",
            "effort": "minimal",
        }
        engine = subagent.engine_spec(profile)
        self.assertEqual(engine["kind"], "claude")
        self.assertEqual(
            engine["argv"],
            [
                "--append-system-prompt", "prose role", "--model", "sonnet",
                "--effort", "low",
            ],
        )

    def test_claude_engine_keeps_a_supported_effort(self):
        profile = {"role": "r", "model": "claude-code/sonnet", "effort": "high"}
        engine = subagent.engine_spec(profile)
        self.assertIn("--effort", engine["argv"])
        self.assertEqual(engine["argv"][engine["argv"].index("--effort") + 1], "high")


class EffortCapTest(TempRepoTest):
    """The effort ceiling is keyed by model name, so the same model is capped
    on every provider (regression: it used to be keyed provider/model, so the
    cap stopped applying when a model moved provider)."""

    def choose(self, model_id, effort):
        answers = {"effort": {"choice": effort}, "model": {"choice": "builder"}}
        with mock.patch.object(subagent, "jev", return_value=answers):
            with mock.patch.dict(subagent.MODELS, {"builder": (model_id, "test")}):
                with contextlib.redirect_stderr(io.StringIO()):
                    return subagent.choose_profile("do the thing", "build", None)

    def test_the_cap_holds_for_the_same_model_on_any_provider(self):
        for provider in ("github-copilot", "another-provider"):
            for effort in ("xhigh", "max"):
                with self.subTest(provider=provider, effort=effort):
                    profile = self.choose(f"{provider}/gpt-6.1-sol", effort)
                    self.assertEqual(profile["effort"], "medium")

    def test_builder_and_writer_use_haiku_5_5_without_effort_ceiling(self):
        answers = {"effort": {"choice": "max"}, "model": {"choice": "builder"}}
        for stage in ("build", "write"):
            with self.subTest(stage=stage):
                spec = subagent.stage_spec(stage, None)
                with mock.patch.object(subagent, "jev", return_value=answers):
                    with contextlib.redirect_stderr(io.StringIO()):
                        profile = subagent.choose_profile("brief", stage, spec["model"])
                self.assertEqual(profile["model"], "claude-code/claude-haiku-5-5")
                self.assertEqual(profile["effort"], "max")
                profile["role"] = spec["role"]
                engine = subagent.engine_spec(profile)
                self.assertEqual(engine["kind"], "claude")
                self.assertEqual(
                    engine["argv"][engine["argv"].index("--model") + 1],
                    "claude-haiku-5-5",
                )
                self.assertEqual(engine["argv"][engine["argv"].index("--effort") + 1], "max")

    def test_the_critic_keeps_its_existing_effort_ceiling(self):
        profile = self.choose("github-copilot/gpt-6.1-sol", "max")
        self.assertEqual(profile["effort"], "medium")

    def test_the_cap_only_ever_lowers_an_effort(self):
        profile = self.choose("github-copilot/gpt-6.1-sol", "low")
        self.assertEqual(profile["effort"], "low")
        profile = self.choose("opencode-go/some-uncapped-model", "max")
        self.assertEqual(profile["effort"], "max")

    def test_jev_failure_falls_back_to_the_default_model(self):
        with mock.patch.object(
            subagent, "jev", side_effect=subagent.urllib.error.URLError("offline")
        ):
            with contextlib.redirect_stderr(io.StringIO()):
                profile = subagent.choose_profile("brief", "build", None)
        self.assertEqual(profile["model"], subagent.MODELS["builder"][0])
        self.assertIsNone(profile["effort"])


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

    def test_prove_needs_at_least_one_verify_skill(self):
        with self.assertRaises(SystemExit) as caught:
            subagent.stage_skills("prove", {"skills": []}, self.repo)
        self.assertIn("verify", str(caught.exception))

    def test_prove_loads_every_verify_skill(self):
        write_skill(self.repo, "verify-web")
        write_skill(self.repo, "verify-api")
        skills = subagent.stage_skills("prove", {"skills": []}, self.repo)
        self.assertEqual(sorted(skills), ["verify-api", "verify-web"])


class StagesTableTest(TempRepoTest):
    def test_stages_table_lists_every_stage_and_its_pinned_model(self):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(subagent.print_stages(), 0)
        table = stdout.getvalue()
        for stage in subagent.STAGES:
            self.assertIn(stage, table)
        self.assertIn("writer: claude-code/claude-haiku-5-5", table)


if __name__ == "__main__":
    unittest.main()

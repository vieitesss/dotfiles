#!/usr/bin/env python3
"""Regression tests for subagent.py's Stage preparation.

Every test runs offline and launches nothing: Jev is stubbed, HOME points at a
temp dir, and no session host is ever resolved.
"""

import contextlib
import io
import os
import shlex
import subprocess
import tempfile
import unittest
from unittest import mock

import subagent
from test_support import prepare_spec

BUILDER_MODEL = subagent.MODELS["builder"][0]


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
        fake_bin = os.path.join(base.name, "bin")
        os.makedirs(fake_bin)
        recado = os.path.join(fake_bin, "recado")
        with open(recado, "w", encoding="utf-8") as handle:
            handle.write('#!/bin/sh\nif [ "$1" = whoami ]; then echo recado://local/manager-1; fi\n')
        os.chmod(recado, 0o755)
        env = mock.patch.dict(os.environ, {"HOME": os.path.join(base.name, "home"),
                                          "PATH": fake_bin + os.pathsep + os.environ["PATH"]})
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


class RecadoRouteTest(TempRepoTest):
    def setUp(self):
        super().setUp()
        write_skill(self.repo, "tdd")
        write_skill(self.repo, "coding")
        self.bin = os.path.join(self.repo, "bin")
        os.makedirs(self.bin)
        clean_path = os.pathsep.join(
            directory for directory in os.environ["PATH"].split(os.pathsep)
            if not os.path.isfile(os.path.join(directory, "recado"))
        )
        env = mock.patch.dict(os.environ, {"PATH": self.bin + os.pathsep + clean_path})
        env.start()
        self.addCleanup(env.stop)
        self.extension_path = os.path.join(
            os.path.dirname(os.path.dirname(__file__)), "extensions", "rex.md"
        )

    def executable(self, name, body):
        path = os.path.join(self.bin, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("#!/bin/sh\n" + body)
        os.chmod(path, 0o755)
        return path

    def test_local_and_remote_preparation_fills_exact_commands(self):
        self.executable("recado", 'if [ "$1" = whoami ]; then echo recado://local/manager-1; fi\n')
        remote = os.path.join(os.path.dirname(self.extension_path), "rex-remote.md")
        upstream = "recado+upstream://manager.local/manager-1"
        for extension, address in ((self.extension_path, "recado://local/manager-1"), (remote, upstream)):
            with self.subTest(extension=extension):
                extra = ("--manager-recado", upstream) if extension == remote else ()
                spec = self.prepare("--extension", extension, "--manager", "block:manager",
                                    *extra, "--dry-run")
                prompt = spec["prompt"]
                self.assertEqual(spec["manager"], "block:manager")
                self.assertEqual(spec["recado_bin_dir"], self.bin)
                self.assertIn(
                    f'recado send {address} --kind complete --meta item=wi-1 '
                    f'--meta stage=build --meta report={spec["report"]} '
                    f'"[{spec["tag"]}] TASK COMPLETE: <one line>"', prompt,
                )
                self.assertIn(f'recado ask {address} "[{spec["tag"]}] QUESTION: <question>"', prompt)
                self.assertNotIn(upstream if extension != remote else "recado://local/manager-1", prompt)
                if extension == remote:
                    self.assertIn("kickoff is not a follow-up", prompt)

    def test_missing_recado_is_installed_and_setup_off_path(self):
        template = self.executable(
            "template", 'if [ "$1" = whoami ]; then echo recado://local/manager-1; '
            'elif [ "$1" = skill ]; then echo setup > "$SETUP_LOG"; fi\n',
        )
        self.executable("go", 'printf \'{"GOBIN":"%s","GOPATH":"%s"}\\n\' "$GOBIN" "$GOPATH"\n')
        install = self.executable("install-recado", '/bin/cp "$TEMPLATE" "$INSTALL_DIR/recado"\n')
        remote = os.path.join(os.path.dirname(self.extension_path), "rex-remote.md")
        gopath = os.path.join(self.repo, "go path")
        for old_binary in (False, True):
            if old_binary:
                self.executable("recado", "exit 1\n")  # no send or update
            for gobin, installed in ((os.path.join(self.repo, "go bin"), os.path.join(self.repo, "go bin")),
                                      ("", os.path.join(gopath, "bin"))):
                os.makedirs(installed, exist_ok=True)
                env = {"GOBIN": gobin, "GOPATH": gopath, "INSTALL_DIR": installed,
                       "TEMPLATE": template, "SETUP_LOG": os.path.join(self.repo, "setup-log"),
                       "RECADO_INSTALL_CMD": shlex.quote(install)}
                with mock.patch.dict(os.environ, env):
                    for extension, extra in ((self.extension_path, ()),
                                             (remote, ("--manager-recado", "recado+upstream://host/manager"))):
                        with self.subTest(old=old_binary, gobin=gobin, extension=extension):
                            spec = self.prepare("--extension", extension, "--dry-run", *extra)
                            self.assertIn(shlex.quote(os.path.join(installed, "recado")) + " send", spec["prompt"])
                            self.assertEqual(spec["recado_bin_dir"], installed)
                self.assertTrue(os.path.isfile(env["SETUP_LOG"]))
                os.remove(env["SETUP_LOG"])

    def test_outdated_recado_uses_update_and_its_install_override(self):
        installed = os.path.join(self.repo, "gobin")
        os.makedirs(installed)
        template = self.executable(
            "template", 'if [ "$1" = whoami ]; then echo recado://local/manager-1; '
            'elif [ "$1" = skill ]; then echo duplicate-setup >> "$LOG"; fi\n',
        )
        self.executable("go", 'printf \'{"GOBIN":"%s","GOPATH":""}\\n\' "$GOBIN"\n')
        install = self.executable("install-recado", '/bin/cp "$TEMPLATE" "$GOBIN/recado"\n')
        self.executable("recado", 'case "$1:$2" in\n'
                        'send:--help) exit 1 ;;\n'
                        'update:--help) exit 0 ;;\n'
                        'update:) /bin/sh -c "$RECADO_INSTALL_CMD" || exit 1; echo setup >> "$LOG" ;;\n'
                        '*) exit 1 ;; esac\n')
        log = os.path.join(self.repo, "update-log")
        with mock.patch.dict(os.environ, {"GOBIN": installed, "TEMPLATE": template,
                                         "LOG": log, "RECADO_INSTALL_CMD": shlex.quote(install)}):
            spec = self.prepare("--extension", self.extension_path, "--dry-run")
        self.assertIn(shlex.quote(os.path.join(installed, "recado")) + " send", spec["prompt"])
        self.assertEqual(spec["recado_bin_dir"], installed)
        with open(log, encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "setup\n")

    def test_update_in_place_needs_no_go_path_lookup(self):
        self.executable("recado", 'case "$1:$2" in\n'
                        'send:--help|ask:--help) test -f "$UPDATED" ;;\n'
                        'update:--help) exit 0 ;;\n'
                        'update:) /bin/sh -c "$RECADO_INSTALL_CMD" ;;\n'
                        'whoami:) echo recado://local/manager-1 ;;\n'
                        '*) exit 1 ;; esac\n')
        updated = os.path.join(self.repo, "updated")
        env = {"UPDATED": updated, "RECADO_INSTALL_CMD": "touch " + shlex.quote(updated)}
        with mock.patch.dict(os.environ, env):
            spec = self.prepare("--extension", self.extension_path, "--dry-run")
        self.assertIn("recado send recado://local/manager-1", spec["prompt"])
        self.assertEqual(spec["recado_bin_dir"], self.bin)
        self.assertTrue(os.path.isfile(updated))

    def test_update_failure_uses_the_same_failure_routes(self):
        self.executable("recado", 'case "$1:$2" in update:--help) exit 0 ;; *) exit 1 ;; esac\n')
        remote = os.path.join(os.path.dirname(self.extension_path), "rex-remote.md")
        with self.assertRaisesRegex(SystemExit, "requires a messaging-capable recado"):
            self.prepare("--extension", self.extension_path, "--dry-run")
        with self.assertRaisesRegex(SystemExit, "requires a messaging-capable recado"):
            self.prepare("--extension", remote, "--manager-recado",
                         "recado+upstream://host/manager", "--dry-run")

    def test_failed_install_stops_local_and_remote_preparation(self):
        self.executable("go", "exit 0\n")
        remote = os.path.join(os.path.dirname(self.extension_path), "rex-remote.md")
        with mock.patch.dict(os.environ, {"RECADO_INSTALL_CMD": "exit 1"}):
            for extension, extra in ((self.extension_path, ()),
                                     (remote, ("--manager-recado", "recado+upstream://host/manager"))):
                with self.subTest(extension=extension):
                    with self.assertRaisesRegex(SystemExit, "requires a messaging-capable recado"):
                        self.prepare("--extension", extension, "--dry-run", *extra)

    def test_unavailable_or_nonlocal_manager_stops_preparation(self):
        for response in ('exit 1', 'echo recado://other/manager', 'echo recado://local/'):
            with self.subTest(response=response):
                self.executable("recado", f'if [ "$1" = whoami ]; then {response}; fi\n')
                with self.assertRaisesRegex(SystemExit, "restart the Manager"):
                    self.prepare("--extension", self.extension_path, "--dry-run")

    def test_recado_without_ask_cannot_prepare_a_stage(self):
        self.executable("recado", 'case "$1" in ask) exit 1 ;; whoami) echo recado://local/manager-1 ;; esac\n')
        with mock.patch.dict(os.environ, {"RECADO_INSTALL_CMD": "exit 1"}):
            with self.assertRaisesRegex(SystemExit, "requires a messaging-capable recado"):
                self.prepare("--extension", self.extension_path, "--dry-run")

    def test_per_session_extension_uses_recado(self):
        self.executable("recado", 'if [ "$1" = whoami ]; then echo recado://local/manager-1; fi\n')
        spec = self.prepare("--extension", self.extension(), "--dry-run")
        self.assertIn("recado send recado://local/manager-1", spec["prompt"])

    def test_remote_preparation_rejects_missing_or_invalid_upstream(self):
        for name in ("rex-remote.md", "paseo-remote.md"):
            remote = os.path.join(os.path.dirname(self.extension_path), name)
            for extra in ((), ("--manager-recado", "recado://local/manager"),
                          ("--manager-recado", "recado+upstream://host/Bad-ID")):
                with self.subTest(extension=name, extra=extra):
                    with self.assertRaises(SystemExit) as caught:
                        self.prepare("--extension", remote, "--dry-run", *extra)
                    self.assertIn("requires --manager-recado", str(caught.exception))

    def test_remote_paseo_requires_and_uses_manager_upstream(self):
        remote = os.path.join(os.path.dirname(self.extension_path), "paseo-remote.md")
        self.executable("recado", 'if [ "$1" = whoami ]; then exit 1; fi\n')
        with self.assertRaisesRegex(SystemExit, "requires --manager-recado"):
            self.prepare("--extension", remote, "--dry-run")
        upstream = "recado+upstream://mac.local/manager-1"
        spec = self.prepare("--extension", remote, "--manager-recado", upstream, "--dry-run")
        self.assertIn(f"recado send {upstream}", spec["prompt"])
        self.assertIn(f"recado ask {upstream}", spec["prompt"])
        self.assertIn("kickoff is not a follow-up", spec["prompt"])

    def test_review_route_includes_axis_metadata(self):
        write_skill(self.repo, "review")
        self.executable("recado", 'if [ "$1" = whoami ]; then echo recado://local/manager-1; fi\n')
        spec = self.prepare("--extension", self.extension_path, "--dry-run",
                            "--stage", "review", "--axis", "spec")
        self.assertIn("--meta item=wi-1 --meta stage=review --meta axis=spec", spec["prompt"])

    def test_shell_metacharacters_in_item_are_not_expanded(self):
        self.executable("recado", 'if [ "$1" = whoami ]; then echo recado://local/manager-1; '
                        'elif [ "$2" != "--help" ]; then printf "%s\\n" "$@"; fi\n')
        spec = self.prepare("--extension", self.extension_path, "--item", 'x$HOME"y', "--dry-run")
        command = next(line for line in spec["prompt"].splitlines() if line.startswith("recado send "))
        result = subprocess.run(command, shell=True, text=True, capture_output=True, check=True)
        self.assertIn('item=x$HOME"y', result.stdout)
        self.assertIn(f'[{spec["tag"]}] TASK COMPLETE:', result.stdout)

    def test_failed_setup_or_missing_send_stops_preparation(self):
        installed = os.path.join(self.repo, "gobin")
        os.makedirs(installed)
        self.executable("go", 'printf \'{"GOBIN":"%s","GOPATH":""}\\n\' "$GOBIN"\n')
        install = self.executable("install-recado", '/bin/cp "$TEMPLATE" "$GOBIN/recado"\n')
        env = {"GOBIN": installed, "RECADO_INSTALL_CMD": shlex.quote(install)}
        for body in ('if [ "$1" = skill ]; then exit 1; fi\n', 'exit 1\n'):
            with self.subTest(body=body):
                env["TEMPLATE"] = self.executable("template", body)
                with mock.patch.dict(os.environ, env):
                    with self.assertRaisesRegex(SystemExit, "requires a messaging-capable recado"):
                        self.prepare("--extension", self.extension_path, "--dry-run")


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
        self.assertIn("recado://local/manager-1", prompt)
        self.assertIn("tdd", prompt)
        self.assertIn("coding", prompt)
        self.assertIn(subagent.SUBAGENT_RULES, prompt)
        self.assertIn("do the thing", prompt)

    def test_prompt_checks_the_reporting_route_before_starting_the_stage(self):
        prompt = self.spec["prompt"]
        self.assertIn("complete route", prompt)
        self.assertIn("never retype", prompt)
        self.assertIn("recado ask recado://local/manager-1", prompt)

    def test_prompt_gives_the_spec_report_precedence_over_the_brief(self):
        prompt = self.spec["prompt"]
        self.assertIn("wins over any path in the brief", prompt)

    def test_the_prompt_fills_in_the_tag_for_every_host(self):
        # Regression: Subagents filled in [TAG] themselves and sent
        # [build], [subagent-review-73082] and [permission-card ].
        write_skill(self.repo, "review")
        spec = self.prepare("--stage", "review", "--axis", "debt")
        self.assertEqual(spec["tag"], f"{spec['name']} · wi-1 · review debt")
        self.assertIn(f"with [{spec['tag']}]", spec["prompt"])
        # Read-only reviewers must still report and wait for an answer.
        for instruction in ("a read-only one included", "end your turn", "Do not use intercom"):
            self.assertIn(instruction, spec["prompt"])


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
            self.assertIn("recado send recado://local/manager-1", spec["prompt"])


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
        self.assertEqual(extension, spec["extension"])
        self.assertEqual("add ress", spec["manager"])
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
            "model": BUILDER_MODEL,
            "effort": "high",
        }
        engine = subagent.engine_spec(profile)
        self.assertEqual(engine["kind"], "pi")
        self.assertEqual(
            engine["argv"],
            [
                "--append-system-prompt", "role text",
                "--model", BUILDER_MODEL,
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
                    self.assertEqual(profile["effort"], "high")

    def test_critic_runs_gpt_6_1_sol_under_its_effort_ceiling(self):
        # HOME is a temp dir here, so no models store is read and the effort
        # arrives unclamped; this pins the ceiling, not the model's own levels.
        answers = {"effort": {"choice": "max"}, "model": {"choice": "builder"}}
        spec = subagent.stage_spec("review", "standards")
        with mock.patch.object(subagent, "jev", return_value=answers):
            with contextlib.redirect_stderr(io.StringIO()):
                profile = subagent.choose_profile("brief", "review", spec["model"])
        self.assertEqual(profile["model"], "github-copilot/gpt-6.1-sol")
        self.assertEqual(profile["effort"], "high")
        profile["role"] = spec["role"]
        engine = subagent.engine_spec(profile)
        self.assertEqual(engine["kind"], "pi")
        self.assertEqual(
            engine["argv"][engine["argv"].index("--model") + 1],
            "github-copilot/gpt-6.1-sol",
        )
        self.assertEqual(engine["argv"][engine["argv"].index("--thinking") + 1], "high")

    def test_builder_effort_clamps_to_the_levels_its_model_offers(self):
        """A model without a `medium` level gets the next level up instead."""
        levels = ["low", "high", "max"]
        answers = {"effort": {"choice": "medium"}, "model": {"choice": "builder"}}
        with mock.patch.object(subagent, "model_thinking_levels", return_value=levels):
            with mock.patch.dict(subagent.MODELS, {"builder": ("opencode-go/uncapped", "test")}):
                with mock.patch.object(subagent, "jev", return_value=answers):
                    with contextlib.redirect_stderr(io.StringIO()):
                        profile = subagent.choose_profile("brief", "build", None)
        self.assertEqual(profile["effort"], "high")

    def test_writer_uses_haiku_5_5_without_effort_ceiling(self):
        answers = {"effort": {"choice": "max"}, "model": {"choice": "builder"}}
        spec = subagent.stage_spec("write", None)
        with mock.patch.object(subagent, "jev", return_value=answers):
            with contextlib.redirect_stderr(io.StringIO()):
                profile = subagent.choose_profile("brief", "write", spec["model"])
        self.assertEqual(profile["model"], "github-copilot/claude-haiku-5.5")
        self.assertEqual(profile["effort"], "max")
        profile["role"] = spec["role"]
        engine = subagent.engine_spec(profile)
        self.assertEqual(engine["kind"], "pi")
        self.assertEqual(
            engine["argv"][engine["argv"].index("--model") + 1],
            "github-copilot/claude-haiku-5.5",
        )
        self.assertEqual(engine["argv"][engine["argv"].index("--thinking") + 1], "max")

    def test_the_cap_only_ever_lowers_an_effort(self):
        profile = self.choose("github-copilot/gpt-6.1-sol", "low")
        self.assertEqual(profile["effort"], "low")
        profile = self.choose("opencode-go/some-uncapped-model", "max")
        self.assertEqual(profile["effort"], "max")

    def test_model_override_takes_a_role_or_an_id(self):
        answers = {"effort": {"choice": "high"}, "model": {"choice": "builder"}}
        with mock.patch.object(subagent, "jev", return_value=answers) as jev:
            with contextlib.redirect_stderr(io.StringIO()):
                by_role = subagent.choose_profile("brief", "build", "critic")
                by_id = subagent.choose_profile("brief", "build", "opencode/other-model")
        self.assertEqual(by_role["model"], subagent.MODELS["critic"][0])
        self.assertEqual(by_id["model"], "opencode/other-model")
        for call in jev.call_args_list:
            self.assertNotIn("model", call.args[1])

    def test_model_override_reaches_the_spec(self):
        write_skill(self.repo, "tdd")
        write_skill(self.repo, "coding")
        with mock.patch.object(subagent, "jev", side_effect=RuntimeError("offline")):
            with contextlib.redirect_stderr(io.StringIO()):
                spec = self.prepare("--model", "claude-code/claude-opus-5-5")
        self.assertEqual(spec["model"], "claude-code/claude-opus-5-5")
        self.assertEqual(spec["engine"]["kind"], "claude")

    def test_model_override_refuses_a_bare_name(self):
        with self.assertRaises(SystemExit):
            with contextlib.redirect_stderr(io.StringIO()):
                subagent.parse_args([
                    "--stage", "build", "--item", "wi-1", "--extension", "x",
                    "--manager", "m", "--model", "opus", "brief",
                ])

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
        self.assertIn("writer: github-copilot/claude-haiku-5.5", table)


if __name__ == "__main__":
    unittest.main()

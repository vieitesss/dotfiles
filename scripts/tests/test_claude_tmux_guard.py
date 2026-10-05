#!/usr/bin/env python3
"""Tests for the Claude Code guard adapter, settings fragment, and launcher."""

import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from importlib.machinery import SourceFileLoader

sys.dont_write_bytecode = True
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO, "scripts", "lib"))

import tmux_guard  # noqa: E402

ADAPTER = os.path.join(REPO, "scripts", "claude-tmux-guard")
LAUNCHER = os.path.join(REPO, "scripts", "claude-guarded")
SETTINGS = os.path.join(REPO, "claude", "tmux-guard.settings.json")


def load_module(path, name):
    loader = SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


ADAPTER_MODULE = load_module(ADAPTER, "claude_tmux_guard")


def bash_payload(command, **extra):
    payload = {
        "session_id": "test",
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": command},
        "cwd": "/work",
    }
    payload.update(extra)
    return payload


def decision_from(out):
    return json.loads(out)["hookSpecificOutput"]


def write_stub(path, body="printf 'stub-json\\n'\n"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("#!/bin/sh\n" + body)
    os.chmod(path, 0o755)
    return path


def run_shell(command, env=None, stdin=None):
    return subprocess.run(
        ["sh", "-c", command],
        env=dict(os.environ) if env is None else env,
        input=stdin,
        capture_output=True,
        text=True,
        check=False,
    )


class AdapterMappingTests(unittest.TestCase):
    def test_destructive_command_asks(self):
        code, out, err = ADAPTER_MODULE.respond(bash_payload("tmux kill-server"))
        self.assertEqual(0, code)
        self.assertEqual("", err)
        self.assertEqual("ask", decision_from(out)["permissionDecision"])
        self.assertTrue(decision_from(out)["permissionDecisionReason"])

    def test_harmless_command_is_silent(self):
        code, out, err = ADAPTER_MODULE.respond(bash_payload("tmux ls"))
        self.assertEqual((0, "", ""), (code, out, err))

    def test_powershell_is_covered(self):
        payload = bash_payload("tmux kill-server")
        payload["tool_name"] = "PowerShell"
        code, out, _ = ADAPTER_MODULE.respond(payload)
        self.assertEqual("ask", decision_from(out)["permissionDecision"])

    def test_no_prompt_modes_deny(self):
        for mode in ("bypassPermissions", "dontAsk"):
            code, out, _ = ADAPTER_MODULE.respond(
                bash_payload("tmux kill-server", permission_mode=mode)
            )
            self.assertEqual(0, code, mode)
            decision = decision_from(out)
            self.assertEqual("deny", decision["permissionDecision"], mode)
            self.assertIn(mode, decision["permissionDecisionReason"])

    def test_other_tools_are_ignored(self):
        payload = bash_payload("tmux kill-server")
        payload["tool_name"] = "Read"
        self.assertEqual((0, "", ""), ADAPTER_MODULE.respond(payload))

    def test_other_events_are_ignored(self):
        payload = bash_payload("tmux kill-server", hook_event_name="PostToolUse")
        self.assertEqual((0, "", ""), ADAPTER_MODULE.respond(payload))

    def test_missing_command_fails_closed(self):
        payload = bash_payload("")
        payload["tool_input"] = {}
        code, out, err = ADAPTER_MODULE.respond(payload)
        self.assertEqual(2, code)
        self.assertIn("command", err)

    def test_cwd_and_command_reach_the_evaluator(self):
        seen = {}

        def evaluator(command, *, cwd, env):
            seen["command"] = command
            seen["cwd"] = cwd
            return tmux_guard.Decision("allow")

        ADAPTER_MODULE.respond(bash_payload("tmux ls", cwd="/somewhere"), evaluator)
        self.assertEqual("tmux ls", seen["command"])
        self.assertEqual("/somewhere", seen["cwd"])

    def test_evaluator_failure_exits_two(self):
        def boom(command, *, cwd, env):
            raise RuntimeError("boom")

        code = ADAPTER_MODULE.main(io.StringIO(json.dumps(bash_payload("tmux ls"))), boom)
        self.assertEqual(2, code)


class AdapterCliTests(unittest.TestCase):
    def run_adapter(self, stdin_text):
        return subprocess.run(
            [sys.executable, ADAPTER],
            input=stdin_text,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_ask_json_on_stdout(self):
        proc = self.run_adapter(json.dumps(bash_payload("tmux kill-server")))
        self.assertEqual(0, proc.returncode, proc.stderr)
        lines = proc.stdout.splitlines()
        self.assertEqual(1, len(lines))
        self.assertEqual("ask", decision_from(lines[0])["permissionDecision"])

    def test_allow_emits_nothing(self):
        proc = self.run_adapter(json.dumps(bash_payload("tmux ls")))
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertEqual("", proc.stdout)

    def test_invalid_json_exits_two(self):
        proc = self.run_adapter("{not json")
        self.assertEqual(2, proc.returncode)
        self.assertIn("could not parse", proc.stderr)

    def test_empty_input_exits_two(self):
        proc = self.run_adapter("")
        self.assertEqual(2, proc.returncode)
        self.assertIn("could not parse", proc.stderr)


class AdapterCoreFailureTests(unittest.TestCase):
    """A missing or broken core module must exit 2, never 1 (Claude fail-open)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="claude-adapter-core.")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.payload = json.dumps(bash_payload("tmux kill-server"))

    def run_copied_adapter(self, lib_body=None):
        adapter = os.path.join(self.tmp, "claude-tmux-guard")
        shutil.copyfile(ADAPTER, adapter)
        os.chmod(adapter, 0o755)
        if lib_body is not None:
            lib_dir = os.path.join(self.tmp, "lib")
            os.makedirs(lib_dir)
            with open(os.path.join(lib_dir, "tmux_guard.py"), "w", encoding="utf-8") as handle:
                handle.write(lib_body)
        return subprocess.run(
            [adapter],
            input=self.payload,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_missing_core_module_exits_two(self):
        proc = self.run_copied_adapter()
        self.assertEqual(2, proc.returncode, proc.stdout)
        self.assertIn("cannot load the tmux_guard core", proc.stderr)

    def test_broken_core_module_exits_two(self):
        proc = self.run_copied_adapter('raise RuntimeError("broken core")\n')
        self.assertEqual(2, proc.returncode, proc.stdout)
        self.assertIn("cannot load the tmux_guard core", proc.stderr)
        self.assertIn("broken core", proc.stderr)

    def test_adapter_stdout_is_only_json_on_success(self):
        proc = subprocess.run(
            [sys.executable, ADAPTER],
            input=self.payload,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertEqual(1, len(proc.stdout.splitlines()))


class SettingsFragmentTests(unittest.TestCase):
    def setUp(self):
        with open(SETTINGS, encoding="utf-8") as handle:
            self.settings = json.load(handle)
        self.command = self.settings["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
        self.tmp = tempfile.mkdtemp(prefix="claude-guard-test.")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def write_stub(self, path, body="printf 'stub-json\\n'\n"):
        return write_stub(path, body)

    def test_shape(self):
        entry = self.settings["hooks"]["PreToolUse"][0]
        self.assertEqual("Bash|PowerShell", entry["matcher"])
        self.assertEqual("command", entry["hooks"][0]["type"])
        self.assertLessEqual(entry["hooks"][0]["timeout"], 10)
        self.assertIn("exit 2", self.command)
        self.assertIn("-ne 0", self.command)

    def run_wrapper(self, env, stdin=None):
        return run_shell(self.command, env=env, stdin=stdin)

    def test_env_guard_is_used(self):
        guard = self.write_stub(os.path.join(self.tmp, "guard"))
        env = dict(os.environ, CLAUDE_TMUX_GUARD=guard)
        proc = self.run_wrapper(env)
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertIn("stub-json", proc.stdout)

    def test_installed_path_is_used(self):
        self.write_stub(
            os.path.join(self.tmp, "home", ".local", "bin", "claude-tmux-guard")
        )
        env = {key: value for key, value in os.environ.items() if key != "CLAUDE_TMUX_GUARD"}
        env["HOME"] = os.path.join(self.tmp, "home")
        proc = self.run_wrapper(env)
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertIn("stub-json", proc.stdout)

    def test_paths_with_spaces_apostrophes_and_dollars_work(self):
        guard = self.write_stub(
            os.path.join(self.tmp, "guard dir's $HOME", "claude-tmux-guard")
        )
        env = dict(os.environ, CLAUDE_TMUX_GUARD=guard)
        proc = self.run_wrapper(env)
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertIn("stub-json", proc.stdout)

    def test_any_nonzero_adapter_status_becomes_exit_two(self):
        for code in (1, 2, 126, 127):
            guard = self.write_stub(os.path.join(self.tmp, f"guard-{code}"), f"exit {code}\n")
            env = dict(os.environ, CLAUDE_TMUX_GUARD=guard)
            proc = self.run_wrapper(env)
            self.assertEqual(2, proc.returncode, (code, proc.stderr))
            self.assertIn("refusing to run unguarded", proc.stderr)

    def test_missing_interpreter_becomes_exit_two(self):
        guard = os.path.join(self.tmp, "no-interpreter")
        with open(guard, "w", encoding="utf-8") as handle:
            handle.write("#!/nonexistent/python3\n")
        os.chmod(guard, 0o755)
        env = dict(os.environ, CLAUDE_TMUX_GUARD=guard)
        proc = self.run_wrapper(env)
        self.assertEqual(2, proc.returncode, proc.stderr)
        self.assertIn("refusing to run unguarded", proc.stderr)

    def test_ask_json_is_preserved_on_success(self):
        guard = self.write_stub(
            os.path.join(self.tmp, "guard"),
            'printf \'{"hookSpecificOutput":{"hookEventName":"PreToolUse",'
            '"permissionDecision":"ask","permissionDecisionReason":"stub"}}\n\'\n',
        )
        env = dict(os.environ, CLAUDE_TMUX_GUARD=guard)
        proc = self.run_wrapper(env)
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertEqual("ask", decision_from(proc.stdout)["permissionDecision"])

    def test_missing_guard_exits_two(self):
        env = {key: value for key, value in os.environ.items() if key != "CLAUDE_TMUX_GUARD"}
        env["HOME"] = os.path.join(self.tmp, "empty-home")
        proc = self.run_wrapper(env)
        self.assertEqual(2, proc.returncode)
        self.assertIn("refusing to run unguarded", proc.stderr)

    def test_real_adapter_runs_through_the_fragment(self):
        env = dict(os.environ, CLAUDE_TMUX_GUARD=ADAPTER)
        proc = self.run_wrapper(env, stdin=json.dumps(bash_payload("tmux kill-server")))
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertEqual("ask", decision_from(proc.stdout)["permissionDecision"])
        allow = self.run_wrapper(env, stdin=json.dumps(bash_payload("tmux ls")))
        self.assertEqual(0, allow.returncode, allow.stderr)
        self.assertEqual("", allow.stdout)


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="claude-guarded-test.")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        self.write_stub(os.path.join(self.bin, "claude"))

    def write_stub(self, path):
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(
                "#!/bin/sh\n"
                'printf "GUARD=%s\\n" "${CLAUDE_TMUX_GUARD:-unset}"\n'
                'i=0\nfor arg in "$@"; do i=$((i + 1)); printf "ARG%d=%s\\n" "$i" "$arg"; done\n'
            )
        os.chmod(path, 0o755)

    def run_launcher(self, launcher, *args):
        env = {key: value for key, value in os.environ.items() if key != "CLAUDE_TMUX_GUARD"}
        env["PATH"] = self.bin + os.pathsep + env.get("PATH", "")
        return subprocess.run(
            [launcher, *args], env=env, capture_output=True, text=True, check=False
        )

    def test_passes_settings_and_guard_path(self):
        proc = self.run_launcher(LAUNCHER, "--version")
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertIn(f"GUARD={os.path.join(REPO, 'scripts', 'claude-tmux-guard')}", proc.stdout)
        self.assertIn(f"ARG1=--settings", proc.stdout)
        self.assertIn(f"ARG2={SETTINGS}", proc.stdout)
        self.assertIn("ARG3=--version", proc.stdout)

    def test_works_through_an_installed_symlink(self):
        link = os.path.join(self.bin, "claude-guarded")
        os.symlink(LAUNCHER, link)
        proc = self.run_launcher(link)
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertIn(f"ARG2={SETTINGS}", proc.stdout)

    def test_missing_claude_exits_two(self):
        env = {"PATH": "/usr/bin:/bin", "HOME": self.tmp}
        proc = subprocess.run(
            [LAUNCHER], env=env, capture_output=True, text=True, check=False
        )
        self.assertEqual(2, proc.returncode)
        self.assertIn("claude not found", proc.stderr)


class SubagentGuardTests(unittest.TestCase):
    def setUp(self):
        self.subagent = load_module(
            os.path.join(REPO, "agents", "skills", "subagents", "scripts", "subagent.py"),
            "subagent_under_test",
        )
        self.tmp = tempfile.mkdtemp(prefix="subagent-guard-test.")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.profile = {"role": "test role", "model": "claude-code/sonnet", "effort": None}

    def settings_command(self, guard):
        settings = json.loads(self.subagent.tmux_guard_settings(guard=guard))
        return settings["hooks"]["PreToolUse"][0]["hooks"][0]["command"]

    def write_stub(self, path, body="printf 'stub-json\\n'\n"):
        return write_stub(path, body)

    def run_command(self, command, env=None):
        return run_shell(command, env=env)

    def test_claude_args_attach_this_checkout_s_guard(self):
        args = self.subagent.claude_args(self.profile, "/tmp/report.md")
        self.assertIn("--settings", args)
        settings = json.loads(args[args.index("--settings") + 1])
        entry = settings["hooks"]["PreToolUse"][0]
        self.assertEqual("Bash|PowerShell", entry["matcher"])
        command = entry["hooks"][0]["command"]
        self.assertIn(os.path.join(REPO, "scripts", "claude-tmux-guard"), command)
        self.assertIn("exit 2", command)
        self.assertEqual("command", entry["hooks"][0]["type"])

    def test_missing_guard_refuses_to_build_settings(self):
        with self.assertRaises(SystemExit):
            self.subagent.tmux_guard_settings(guard=os.path.join(self.tmp, "absent"))

    def test_claude_args_refuse_when_the_guard_is_missing(self):
        original = self.subagent.tmux_guard_settings
        self.subagent.tmux_guard_settings = lambda: None
        try:
            with self.assertRaises(SystemExit):
                self.subagent.claude_args(self.profile, "/tmp/report.md")
        finally:
            self.subagent.tmux_guard_settings = original

    def test_inline_command_runs_a_guard_with_an_awkward_path(self):
        guard = self.write_stub(
            os.path.join(self.tmp, "guard dir's $HOME", "claude-tmux-guard")
        )
        proc = self.run_command(self.settings_command(guard))
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertIn("stub-json", proc.stdout)

    def test_inline_command_maps_any_nonzero_status_to_exit_two(self):
        for code in (1, 2, 126, 127):
            guard = self.write_stub(os.path.join(self.tmp, f"guard-{code}"), f"exit {code}\n")
            proc = self.run_command(self.settings_command(guard))
            self.assertEqual(2, proc.returncode, (code, proc.stderr))
            self.assertIn("refusing to run unguarded", proc.stderr)

    def test_inline_command_refuses_a_missing_or_non_executable_guard(self):
        # A guard that disappears after launch still fails closed at hook time.
        disappearing = self.write_stub(os.path.join(self.tmp, "disappearing"))
        command = self.settings_command(disappearing)
        os.unlink(disappearing)
        proc = self.run_command(command)
        self.assertEqual(2, proc.returncode)
        self.assertIn("refusing to run unguarded", proc.stderr)

        non_exec = os.path.join(self.tmp, "not-executable")
        with open(non_exec, "w", encoding="utf-8") as handle:
            handle.write("#!/bin/sh\nexit 0\n")
        proc = self.run_command(self.settings_command(non_exec))
        self.assertEqual(2, proc.returncode)
        self.assertIn("refusing to run unguarded", proc.stderr)

    def test_inline_command_missing_interpreter_is_exit_two(self):
        guard = os.path.join(self.tmp, "no-interpreter")
        with open(guard, "w", encoding="utf-8") as handle:
            handle.write("#!/nonexistent/python3\n")
        os.chmod(guard, 0o755)
        proc = self.run_command(self.settings_command(guard))
        self.assertEqual(2, proc.returncode)
        self.assertIn("refusing to run unguarded", proc.stderr)

    def test_inline_command_preserves_ask_json_on_success(self):
        guard = self.write_stub(
            os.path.join(self.tmp, "guard"),
            'printf \'{"hookSpecificOutput":{"hookEventName":"PreToolUse",'
            '"permissionDecision":"ask","permissionDecisionReason":"stub"}}\n\'\n',
        )
        proc = self.run_command(self.settings_command(guard))
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertEqual("ask", decision_from(proc.stdout)["permissionDecision"])


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Tests for scripts/tmux-guard and the Claude launchers that use it.

Hermetic: a transport stub replaces HTTP, so no key or network is used.
"""

import importlib.util
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
GUARD = os.path.join(REPO, "scripts", "tmux-guard")
LAUNCHER = os.path.join(REPO, "scripts", "claude-guarded")
SECRET = "ts_secret_do_not_log"


def load(path, name):
    loader = SourceFileLoader(name, path)
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(name, loader))
    loader.exec_module(module)
    return module


guard = load(GUARD, "tmux_guard_under_test")
subagent = load(
    os.path.join(REPO, "agents", "skills", "subagents", "scripts", "subagent.py"),
    "subagent_under_test",
)


def transport_stub(body=None, error=None):
    """A urllib stand-in: records (request, timeout) pairs, returns canned JSON."""
    requests = []

    def transport(request, timeout):
        requests.append((request, timeout))
        if error is not None:
            raise error
        return body

    return transport, requests


def noul(value):
    return {"answers": {"needs_human_approval": {"type": "noul", "noul": value}}}


def screen(command, body=None, error=None, env=None):
    transport, requests = transport_stub(body, error)
    env = {"TYPESAFE_API_KEY": SECRET} if env is None else env
    return guard.screen(command, cwd="/work", env=env, transport=transport), requests


def no_key_env():
    return {k: v for k, v in os.environ.items() if k != "TYPESAFE_API_KEY"}


def payload(command="tmux kill-server", **extra):
    return {"hook_event_name": "PreToolUse", "tool_name": "Bash", "cwd": "/work",
            "tool_input": {"command": command}, **extra}


def hook_command(settings_json):
    return json.loads(settings_json)["hooks"]["PreToolUse"][0]["hooks"][0]["command"]


class ScreenTests(unittest.TestCase):
    def test_prefilter_and_failures(self):
        for command in ("git status", "npm run build", "pkill -f node", ""):
            decision, requests = screen(command, error=AssertionError("called"), env={})
            self.assertEqual((decision, requests), (("allow", ""), []), command)
        for command in ("tmux kill-server", "pkill -f tmux", "echo tmux"):
            # A tmux command reaches the screen even without a key, where it
            # asks; an unrelated command never gets there.
            self.assertEqual(screen(command, error=AssertionError("called"), env={})[0][0], "ask", command)
        missing, requests = screen("tmux kill-server", env={})
        self.assertEqual((missing[0], requests), ("ask", []))
        self.assertIn("TYPESAFE_API_KEY", missing[1])
        failed, _ = screen("tmux kill-server", error=OSError("connection timed out"))
        self.assertTrue(failed[1].endswith("so a human decides"))
        self.assertIn("connection timed out", failed[1])
        self.assertNotIn(SECRET, failed[1])

    def test_probability_maps_to_allow_or_ask_at_the_threshold(self):
        for value, kind in ((0.02, "allow"), (0.34, "allow"), (0.35, "ask"), (0.5, "ask"), (0.95, "ask")):
            decision, requests = screen("tmux kill-server", body=noul(value))
            self.assertEqual((decision[0], len(requests)), (kind, 1), value)

    def test_unusable_answers_ask(self):
        def answer(value):
            return {"answers": {"needs_human_approval": {"type": "noul", "noul": value}}}

        bodies = [None, {}, {"answers": {}}, {"answers": {"needs_human_approval": {}}},
                  answer("0.9"), answer(True), answer(None)]
        bodies += [answer(value) for value in (float("nan"), float("inf"), -0.01, 1.01)]
        for body in bodies:
            decision, _ = screen("tmux kill-server", body=body)
            self.assertEqual((decision[0], "could not be read" in decision[1]), ("ask", True), body)

    def test_request_shape_carries_policy_context_but_no_other_environment(self):
        command = "tmux -S /tmp/private.sock kill-server"
        transport, requests = transport_stub(noul(0.0))
        env = {"TYPESAFE_API_KEY": SECRET, "TMUX": "/tmp/live.sock,4,0", "EXTRA": "not-for-typesafe"}
        guard.screen(command, cwd="/work/dir", env=env, transport=transport)
        request, timeout = requests[0]
        self.assertEqual((request.full_url, request.get_method()), (guard.API_URL, "POST"))
        self.assertEqual(
            (request.get_header("Authorization"), request.get_header("Content-type")),
            ("Bearer " + SECRET, "application/json"),
        )
        self.assertTrue(0 < timeout <= 5)
        data = json.loads(request.data)
        self.assertEqual(data["model"], "jev-latest")
        self.assertEqual(data["state"], {"command": command, "cwd": "/work/dir", "live_tmux_socket": "/tmp/live.sock"})
        question = data["questions"]["needs_human_approval"]
        self.assertEqual((question["type"], set(question["criteria"])), ("noul", {"true", "false"}))
        self.assertNotIn("not-for-typesafe", request.data.decode())

        fallback, requests = transport_stub(noul(0.0))
        guard.screen("tmux ls", env={"TYPESAFE_API_KEY": SECRET, "TMUX_TMPDIR": "/custom"}, transport=fallback)
        socket = json.loads(requests[0][0].data)["state"]["live_tmux_socket"]
        self.assertEqual(socket, "/custom/tmux-%d/default" % os.getuid())


class CliTests(unittest.TestCase):
    def test_one_line_decisions_and_a_missing_command_exits_two(self):
        def run(*args):
            return subprocess.run([sys.executable, GUARD, *args], env=no_key_env(), capture_output=True, text=True)

        allow = run("git status")
        self.assertEqual((allow.returncode, allow.stdout, allow.stderr), (0, "allow\n", ""))
        ask = run("--cwd", "/tmp", "tmux kill-server")
        self.assertEqual((ask.returncode, ask.stderr, run().returncode), (0, "", 2))
        self.assertTrue(ask.stdout.startswith("ask\t"), ask.stdout)
        self.assertIn("TYPESAFE_API_KEY", ask.stdout)


class ClaudeHookTests(unittest.TestCase):
    def hook(self, data, decision=("ask", "risk 0.80")):
        return guard.claude_hook(data, env={}, decide=lambda command, cwd, env: decision)

    def test_maps_decisions_and_ignores_other_tools_and_events(self):
        self.assertEqual(self.hook(payload(), ("allow", "")), (0, ""))
        code, out = self.hook(payload())
        decision = json.loads(out)["hookSpecificOutput"]
        self.assertEqual((code, decision["hookEventName"], decision["permissionDecision"]), (0, "PreToolUse", "ask"))
        self.assertEqual(decision["permissionDecisionReason"], "risk 0.80")
        for mode in ("bypassPermissions", "dontAsk"):
            reply = self.hook(payload(permission_mode=mode))
            self.assertEqual(json.loads(reply[1])["hookSpecificOutput"]["permissionDecision"], "deny", mode)
        for data in (payload(tool_name="Edit"), payload(hook_event_name="PostToolUse")):
            self.assertEqual(self.hook(data), (0, ""))
        with self.assertRaises(ValueError):
            self.hook({"tool_name": "Bash", "tool_input": {}})

    def test_stdin_mode_answers_offline_and_fails_closed_on_bad_input(self):
        def run(raw):
            return subprocess.run(
                [sys.executable, GUARD, "--claude-hook"], input=raw, capture_output=True, text=True, env=no_key_env()
            )

        bad = run("{not json")
        self.assertEqual((bad.returncode, "bad Claude hook input" in bad.stderr), (2, True))
        offline = run(json.dumps(payload("git status")))
        self.assertEqual((offline.returncode, offline.stdout), (0, ""))
        ask = run(json.dumps(payload("tmux kill-server")))
        self.assertEqual(json.loads(ask.stdout)["hookSpecificOutput"]["permissionDecision"], "ask")


class ClaudeSettingsTests(unittest.TestCase):
    def run_hook_command(self, command, stdin=None):
        return subprocess.run(
            ["sh", "-c", command], input=stdin, capture_output=True, text=True, env=no_key_env()
        )

    def test_policy_is_valid_offline_names_this_guard_and_runs(self):
        proc = subprocess.run(
            [sys.executable, GUARD, "--claude-settings"], capture_output=True, text=True, env=no_key_env()
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        settings = json.loads(guard.claude_settings())
        self.assertEqual(json.loads(proc.stdout), settings)
        entry = settings["hooks"]["PreToolUse"][0]
        command = entry["hooks"][0]["command"]
        self.assertEqual(entry["matcher"], "Bash|PowerShell")
        self.assertTrue(0 < entry["hooks"][0]["timeout"] <= 10)
        for expected in (os.path.realpath(GUARD), "--claude-hook", "exit 2"):
            self.assertIn(expected, command)
        offline = self.run_hook_command(command, json.dumps(payload("git status")))
        self.assertEqual((offline.returncode, offline.stdout), (0, ""))

    def test_the_generated_hook_command_blocks_on_a_failing_guard(self):
        tmp = tempfile.mkdtemp(prefix="guard-stub.")
        self.addCleanup(shutil.rmtree, tmp, True)
        stub = os.path.join(tmp, "guard")
        with open(stub, "w", encoding="utf-8") as handle:
            handle.write("#!/bin/sh\nexit 1\n")
        os.chmod(stub, 0o755)
        proc = self.run_hook_command(hook_command(guard.claude_settings(stub)), "{}")

        self.assertEqual((proc.returncode, "refusing to run unguarded" in proc.stderr), (2, True))


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="claude-guarded-test.")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        stub = os.path.join(self.bin, "claude")
        with open(stub, "w", encoding="utf-8") as handle:
            handle.write('#!/bin/sh\nfor arg in "$@"; do printf "ARG=%s\\n" "$arg"; done\n')
        os.chmod(stub, 0o755)

    def test_claude_guarded_attaches_the_generated_policy(self):
        env = dict(os.environ, PATH=self.bin + os.pathsep + os.environ.get("PATH", ""))
        proc = subprocess.run([LAUNCHER, "--version"], env=env, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = proc.stdout.splitlines()
        command = hook_command(lines[lines.index("ARG=--settings") + 1].removeprefix("ARG="))
        self.assertIn(os.path.realpath(GUARD), command)
        self.assertIn("ARG=--version", lines)
        missing = subprocess.run(
            [LAUNCHER], env={"PATH": "/usr/bin:/bin", "HOME": self.tmp}, capture_output=True, text=True
        )
        self.assertEqual((missing.returncode, "claude not found" in missing.stderr), (2, True))

    def test_the_subagent_launcher_uses_the_same_policy(self):
        settings = subagent.tmux_guard_settings()
        self.assertIn(os.path.realpath(GUARD), hook_command(settings))
        profile = {"role": "test role", "model": "claude-code/sonnet", "effort": None}
        args = subagent.claude_args(profile, "/tmp/report.md")
        self.assertEqual(json.loads(args[args.index("--settings") + 1]), json.loads(settings))


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Tests for the session-host extensions.

Fake `paseo`, `herdr`, and `tmux` executables stand in for the real CLIs and
record every call, so nothing is launched. The one real tmux exercise runs
through scripts/tmux-sandbox, never the live server.
"""

import contextlib
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import subagent
from test_support import prepare_spec

SKILL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(SKILL)))

EXTENSIONS = os.path.join(SKILL, "extensions")
sys.path.insert(0, EXTENSIONS)
import host_launch  # noqa: E402

FAKE_CLI = '''#!/usr/bin/env python3
import json, os, sys

name = os.path.basename(sys.argv[0])
args = sys.argv[1:]
log = os.environ["FAKE_LOG"]
with open(log, "a", encoding="utf-8") as handle:
    handle.write(json.dumps([name, args]) + "\\n")
if "--prompt-file" in args:
    path = args[args.index("--prompt-file") + 1]
    with open(path, encoding="utf-8") as source:
        with open(log, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(["prompt-file", source.read()]) + "\\n")
if name == "paseo" and args[:2] == ["workspace", "ls"]:
    print(os.environ.get("FAKE_WORKSPACES", "[]"))
elif name == "paseo" and args[:1] == ["run"]:
    print(json.dumps({"agentId": "agent-42"}))
elif name == "herdr" and args[:2] == ["tab", "create"]:
    print(json.dumps({"result": {"root_pane": {"pane_id": "1-1"},
                                 "tab": {"tab_id": "1:1"}}}))
elif name == "tmux":
    if args[:1] == ["new-window"]:
        print("@1 %1")
    elif args[:1] == ["display-message"]:
        print("%1 0")
    elif args[:1] == ["load-buffer"]:
        sys.stdin.read()
'''


class HostTest(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.work = work.name
        self.bin = os.path.join(self.work, "bin")
        os.makedirs(self.bin)
        self.log = os.path.join(self.work, "log")
        for name in ("paseo", "herdr", "tmux"):
            path = os.path.join(self.bin, name)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(FAKE_CLI)
            os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP)
        self.env = dict(os.environ)
        self.env.update(
            FAKE_LOG=self.log,
            PATH=os.pathsep.join([self.bin, os.environ.get("PATH", "")]),
            HOME=self.work,
            PASEO_CLI=os.path.join(self.bin, "paseo"),
        )
        self.env.pop("TYPESAFE_API_KEY", None)

    def run_host(self, host, *args, spec=None, env=None):
        command = [
            sys.executable, os.path.join(SKILL, "extensions", host, "host.py"), *args
        ]
        return subprocess.run(
            command,
            input=json.dumps(spec) if spec is not None else None,
            capture_output=True,
            text=True,
            env=env or self.env,
        )

    def calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log, encoding="utf-8") as handle:
            return [json.loads(line) for line in handle if line.strip()]

    def call_for(self, name):
        return [args for called, args in self.calls() if called == name]

    def run_call(self):
        return [args for args in self.call_for("paseo") if args[:1] == ["run"]][0]

    def failing_cli(self, name, message="blocked"):
        directory = os.path.join(self.work, f"fail-{name}")
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(f"#!/bin/sh\nprintf '%s\\n' '{message}' >&2\nexit 1\n")
        os.chmod(path, 0o755)
        return directory

    def script_cli(self, name, body):
        """A fake CLI whose shell body is exactly what the test needs."""
        directory = os.path.join(self.work, f"script-{name}")
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("#!/bin/sh\n" + body)
        os.chmod(path, 0o755)
        return path

    def spec(self, kind="pi", model="opencode-go/deepseek-v4.1-flash", effort="high"):
        role = "STAGE ROLE"
        engine = {"kind": kind, "argv": ["--append-system-prompt", role]}
        if kind == "claude":
            engine["argv"] += ["--model", model.partition("/")[2], "--effort", "low"]
        else:
            engine["argv"] += ["--model", model, "--thinking", effort]
        return {
            "item": "wi",
            "stage": "build",
            "axis": None,
            "name": "subagent-build-1",
            "tag": "subagent-build-1 · wi · build",
            "cwd": os.path.join(self.work, "cwd"),
            "report": os.path.join(self.work, "reports", "wi-build.md"),
            "extension": os.path.join(SKILL, "extensions", "paseo.md"),
            "manager": "manager-addr",
            "model": model,
            "effort": effort if kind != "claude" else "low",
            "role": role,
            "skills": {},
            "engine": engine,
            "prompt": f"{role}\n\nFIRST LINE\nsecond line of brief",
        }


class PaseoHostTest(HostTest):
    def test_a_tmux_manager_address_is_refused_before_any_cli_call(self):
        spec = self.spec(kind="claude", model="claude-code/sonnet")
        spec["extension"] = os.path.join(SKILL, "extensions", "tmux.md")
        spec["manager"] = "%36"
        # Remote execution has no knowledge of the Mac Manager's environment.
        env = dict(self.env)
        env.pop("PASEO_AGENT_ID", None)
        env.pop("PASEO_CLI", None)
        proc = self.run_host("paseo", "launch", spec=spec, env=env)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Manager's Paseo agent id", proc.stderr)
        self.assertEqual(self.calls(), [])

    def test_a_missing_manager_is_refused_before_any_cli_call(self):
        spec = self.spec()
        spec.pop("manager")
        proc = self.run_host("paseo", "launch", spec=spec)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Manager's Paseo agent id", proc.stderr)
        self.assertEqual(self.calls(), [])

    def test_remote_reporting_instructions_are_delivered_without_local_inference(self):
        cwd = os.path.join(self.work, "rpi-checkout")
        os.makedirs(cwd)
        extension = os.path.join(self.work, "remote-paseo.md")
        manager = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        with open(extension, "w", encoding="utf-8") as handle:
            handle.write(
                f"# Paseo Manager on the Mac\n"
                f'paseo --host mac-endpoint send --no-wait {manager} "MESSAGE"\n'
            )
        env = dict(self.env, TMUX_PANE="%36")
        env.pop("PASEO_AGENT_ID", None)
        env.pop("PASEO_CLI", None)
        with mock.patch.dict(os.environ, env, clear=True):
            with mock.patch.object(subagent, "stage_skills", return_value={}):
                spec = prepare_spec([
                    "subagent.py", "--stage", "diagnose", "--item", "remote",
                    "--cwd", cwd, "--extension", extension,
                    "--manager", manager, "--dry-run", "remote brief",
                ])
        proc = self.run_host("paseo", "launch", spec=spec, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        delivered = self.run_call()[-1]
        self.assertEqual(delivered, spec["prompt"])
        self.assertIn(manager, delivered)
        self.assertIn(extension, delivered)
        self.assertNotIn("%36", delivered)

    def test_pi_launch_uses_the_pi_provider_and_full_model(self):
        spec = self.spec()
        proc = self.run_host("paseo", "launch", spec=spec)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["agentId"], "agent-42")

        argv = self.run_call()
        self.assertEqual(argv[:3], ["run", "--background", "--json"])
        self.assertIn("--provider", argv)
        self.assertEqual(argv[argv.index("--provider") + 1], "pi")
        self.assertEqual(argv[argv.index("--model") + 1], spec["model"])
        self.assertEqual(argv[argv.index("--thinking") + 1], "high")
        self.assertEqual(argv[argv.index("--cwd") + 1], spec["cwd"])
        self.assertEqual(argv[argv.index("--title") + 1], spec["name"])
        self.assertEqual(argv[-1], spec["prompt"])

    def test_claude_launch_uses_the_claude_provider_and_alias(self):
        spec = self.spec(kind="claude", model="claude-code/sonnet", effort="low")
        proc = self.run_host("paseo", "launch", spec=spec)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        argv = self.run_call()
        self.assertEqual(argv[argv.index("--provider") + 1], "claude")
        self.assertEqual(argv[argv.index("--model") + 1], "sonnet")
        self.assertEqual(argv[argv.index("--thinking") + 1], "low")

    def test_claude_keeps_permission_checks_through_auto_mode(self):
        proc = self.run_host(
            "paseo", "launch", spec=self.spec(kind="claude", model="claude-code/sonnet")
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        argv = self.run_call()
        self.assertEqual(argv[argv.index("--mode") + 1], "auto")
        self.assertNotIn("bypassPermissions", argv)

    def test_pi_launch_has_no_permission_mode(self):
        proc = self.run_host("paseo", "launch", spec=self.spec())
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("--mode", self.run_call())

    def test_claude_thinking_is_the_effort_core_already_clamped(self):
        spec = self.spec(kind="claude", model="claude-code/sonnet", effort="low")
        spec["effort"] = "minimal"  # Jev's raw pick; core clamps it for Claude
        proc = self.run_host("paseo", "launch", spec=spec)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        argv = self.run_call()
        self.assertEqual(argv[argv.index("--thinking") + 1], "low")
        self.assertNotIn("minimal", argv)

    def test_no_thinking_flag_when_the_engine_carries_none(self):
        spec = self.spec()
        spec["engine"]["argv"] = ["--append-system-prompt", spec["role"]]
        spec["effort"] = None
        proc = self.run_host("paseo", "launch", spec=spec)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("--thinking", self.run_call())

    def test_a_cwd_matching_the_caller_needs_no_workspace(self):
        spec = self.spec()
        env = dict(self.env, PASEO_AGENT_CWD=spec["cwd"])
        proc = self.run_host("paseo", "launch", spec=spec, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        argv = self.run_call()
        self.assertEqual(argv[argv.index("--cwd") + 1], spec["cwd"])
        self.assertNotIn("--workspace", argv)
        self.assertNotIn("--new-workspace", argv)

    def test_an_explicit_workspace_rooted_at_cwd_is_used(self):
        spec = self.spec()
        env = dict(
            self.env,
            FAKE_WORKSPACES=json.dumps(
                [{"workspaceId": "wks-7", "cwd": spec["cwd"]}]
            ),
        )
        proc = self.run_host("paseo", "launch", "wks-7", spec=spec, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        argv = self.run_call()
        self.assertEqual(argv[argv.index("--workspace") + 1], "wks-7")
        self.assertNotIn("--cwd", argv)

    def test_an_explicit_workspace_rooted_elsewhere_is_refused(self):
        # The CLI replaces --cwd with the explicit workspace's own root, so
        # accepting a mismatched id would silently move the Stage elsewhere.
        env = dict(
            self.env,
            FAKE_WORKSPACES=json.dumps(
                [
                    {
                        "workspaceId": "wks-7",
                        "cwd": os.path.join(self.work, "elsewhere"),
                    }
                ]
            ),
        )
        proc = self.run_host("paseo", "launch", "wks-7", spec=self.spec(), env=env)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("refusing to move the Stage", proc.stderr)
        self.assertEqual(
            [
                args
                for args in self.call_for("paseo")
                if args[:1] in (["run"], ["archive"])
            ],
            [],
        )

    def test_an_unknown_explicit_workspace_is_refused(self):
        env = dict(self.env, FAKE_WORKSPACES="[]")
        proc = self.run_host("paseo", "launch", "wks-missing", spec=self.spec(), env=env)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("no live workspace", proc.stderr)
        self.assertEqual(
            [args for args in self.call_for("paseo") if args[:1] == ["run"]], []
        )

    def test_an_explicit_workspace_matching_a_cwd_with_spaces_is_used(self):
        spec = self.spec()
        spec["cwd"] = os.path.join(self.work, "a dir with spaces")
        env = dict(
            self.env,
            FAKE_WORKSPACES=json.dumps(
                [{"workspaceId": "wks-7", "cwd": spec["cwd"]}]
            ),
        )
        proc = self.run_host("paseo", "launch", "wks-7", spec=spec, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        argv = self.run_call()
        self.assertEqual(argv[argv.index("--workspace") + 1], "wks-7")
        self.assertNotIn("--cwd", argv)

    def test_a_worktree_reuses_the_workspace_rooted_there(self):
        spec = self.spec()
        env = dict(
            self.env,
            PASEO_AGENT_CWD=os.path.join(self.work, "elsewhere"),
            FAKE_WORKSPACES=json.dumps([{"workspaceId": "wks-9", "cwd": spec["cwd"]}]),
        )
        proc = self.run_host("paseo", "launch", spec=spec, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        argv = self.run_call()
        self.assertEqual(argv[argv.index("--workspace") + 1], "wks-9")
        self.assertNotIn("--cwd", argv)

    def test_a_worktree_without_a_workspace_mints_a_local_one(self):
        spec = self.spec()
        env = dict(
            self.env,
            PASEO_AGENT_CWD=os.path.join(self.work, "elsewhere"),
            FAKE_WORKSPACES="[]",
        )
        proc = self.run_host("paseo", "launch", spec=spec, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        argv = self.run_call()
        self.assertEqual(argv[argv.index("--new-workspace") + 1], "local")
        self.assertEqual(argv[argv.index("--cwd") + 1], spec["cwd"])
        self.assertIn("creating a local one", proc.stderr)

    def test_send_is_nonblocking_and_reads_a_prompt_file(self):
        proc = self.run_host("paseo", "send", "agent-42", "a\nb")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        argv = self.call_for("paseo")[0]
        self.assertEqual(argv[:3], ["send", "--no-wait", "agent-42"])
        self.assertIn("--prompt-file", argv)
        self.assertIn(["prompt-file", "a\nb"], self.calls())

    def test_archive_keeps_history_and_forces_a_running_agent(self):
        proc = self.run_host("paseo", "archive", "agent-42")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.call_for("paseo")[0], ["archive", "--force", "agent-42"])

    def test_archive_forces_an_agent_the_cli_refuses_while_running(self):
        # The installed CLI rejects `archive` on a running agent unless --force
        # (agent/archive.js: AGENT_RUNNING). A Completion report is sent before
        # the reporting turn ends, so acceptance can arrive mid-turn.
        body = (
            'for a in "$@"; do [ "$a" = "--force" ] && forced=1; done\n'
            'printf "%s\\n" "$*" >> "$ARCHIVE_LOG"\n'
            'if [ "$1" = "archive" ] && [ -z "$forced" ]; then\n'
            "  printf '%s\\n' 'Agent abc1234 is currently running' >&2\n"
            "  exit 1\n"
            "fi\n"
            "exit 0\n"
        )
        log = os.path.join(self.work, "archive-log")
        env = dict(
            self.env,
            PASEO_CLI=self.script_cli("paseo", body),
            ARCHIVE_LOG=log,
        )
        proc = self.run_host("paseo", "archive", "agent-42", env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        with open(log, encoding="utf-8") as handle:
            self.assertEqual(handle.read().strip(), "archive --force agent-42")

    def test_pretty_printed_json_reply_yields_the_agent_id(self):
        # The installed CLI renders `run --json` as pretty-printed multiline
        # JSON (output/json.js: JSON.stringify(data, null, 2)), so the whole
        # reply is one JSON object, not one object per line.
        spec = self.spec()
        reply = json.dumps(
            {
                "agentId": "agent-9",
                "status": "running",
                "provider": "pi",
                "cwd": spec["cwd"],
                "title": spec["name"],
            },
            indent=2,
        )
        cli = self.script_cli("paseo", f"cat <<'JSON'\n{reply}\nJSON\n")
        env = dict(self.env, PASEO_CLI=cli)
        proc = self.run_host("paseo", "launch", spec=spec, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["agentId"], "agent-9")

    def test_a_run_that_lands_outside_cwd_is_archived_and_refused(self):
        # The run reply's own cwd is authoritative: a successful launch in the
        # wrong directory is stopped with the history-preserving archive before
        # the helper refuses to report success.
        spec = self.spec()
        misplaced = os.path.join(self.work, "elsewhere")
        reply = json.dumps({"agentId": "agent-9", "cwd": misplaced})
        log = os.path.join(self.work, "calls")
        body = (
            f'printf "%s\\n" "$*" >> "{log}"\n'
            'if [ "$1" = "run" ]; then\n'
            f"  cat <<'JSON'\n{reply}\nJSON\n"
            "fi\n"
            "exit 0\n"
        )
        env = dict(self.env, PASEO_CLI=self.script_cli("paseo", body))
        proc = self.run_host("paseo", "launch", spec=spec, env=env)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("landed in", proc.stderr)
        self.assertIn(misplaced, proc.stderr)
        self.assertIn(spec["cwd"], proc.stderr)
        self.assertIn("archived the misplaced agent agent-9", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")
        with open(log, encoding="utf-8") as handle:
            self.assertIn("archive --force agent-9", handle.read())

    def test_a_misplaced_run_that_cannot_be_archived_keeps_its_id(self):
        spec = self.spec()
        reply = json.dumps(
            {"agentId": "agent-9", "cwd": os.path.join(self.work, "elsewhere")}
        )
        body = (
            'if [ "$1" = "run" ]; then\n'
            f"  cat <<'JSON'\n{reply}\nJSON\n"
            'elif [ "$1" = "archive" ]; then\n'
            "  printf '%s\\n' 'Agent agent-9 is currently running' >&2\n"
            "  exit 1\n"
            "fi\n"
            "exit 0\n"
        )
        env = dict(self.env, PASEO_CLI=self.script_cli("paseo", body))
        proc = self.run_host("paseo", "launch", spec=spec, env=env)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("landed in", proc.stderr)
        self.assertIn("agent-9 could not be archived", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")

    def test_a_reply_without_a_whole_json_agent_id_is_refused(self):
        # Nothing is guessed: neither a non-JSON reply nor a log line in front
        # of the JSON yields an agent id (the CLI logs to stderr, not stdout).
        for name, body in (
            ("plain", 'printf "not json\\n"\n'),
            (
                "prefixed",
                'printf "starting agent...\\n"\n'
                'printf \'{"agentId": "agent-9"}\\n\'\n',
            ),
        ):
            with self.subTest(name=name):
                env = dict(self.env, PASEO_CLI=self.script_cli(f"paseo-{name}", body))
                proc = self.run_host("paseo", "launch", spec=self.spec(), env=env)
                self.assertNotEqual(proc.returncode, 0)
                self.assertIn("no agent id", proc.stderr)
                self.assertEqual(proc.stdout.strip(), "")

    def test_a_failed_run_never_echoes_the_prompt(self):
        env = dict(self.env)
        env["PASEO_CLI"] = os.path.join(self.failing_cli("paseo"), "paseo")
        proc = self.run_host("paseo", "launch", spec=self.spec(), env=env)
        self.assertNotEqual(proc.returncode, 0)
        self.assertNotIn("STAGE ROLE", proc.stdout + proc.stderr)
        self.assertNotIn("FIRST LINE", proc.stdout + proc.stderr)
        self.assertIn("paseo run failed: blocked", proc.stderr)

    def test_a_cwd_with_spaces_stays_one_argument(self):
        spec = self.spec()
        spec["cwd"] = os.path.join(self.work, "a dir with spaces")
        proc = self.run_host("paseo", "launch", spec=spec)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        argv = self.run_call()
        self.assertEqual(argv[argv.index("--cwd") + 1], spec["cwd"])


class TmuxHostTest(HostTest):
    def test_launch_starts_the_engine_with_the_multiline_prompt(self):
        spec = self.spec()
        proc = self.run_host("tmux", "launch", "sess", spec=spec)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["window"], "@1")
        self.assertEqual(json.loads(proc.stdout)["pane"], "%1")

        window = self.call_for("tmux")[0]
        self.assertEqual(window[:5], ["new-window", "-d", "-P", "-F", "#{window_id} #{pane_id}"])
        self.assertEqual(window[window.index("-t") + 1], "sess:")
        self.assertEqual(window[window.index("-n") + 1], spec["name"])

        respawn = [c for c in self.call_for("tmux") if c[0] == "respawn-pane"][0]
        self.assertIn("pi", respawn)
        self.assertIn(spec["model"], respawn)
        prompt_file = [arg for arg in respawn if arg.endswith(".md") and os.path.isfile(arg)]
        self.assertTrue(prompt_file, respawn)
        with open(prompt_file[0], encoding="utf-8") as handle:
            self.assertEqual(handle.read(), spec["prompt"])

    def test_claude_launch_allows_reporting_and_trusts_the_directory(self):
        spec = self.spec(kind="claude", model="claude-code/sonnet", effort="low")
        os.makedirs(spec["cwd"], exist_ok=True)
        proc = self.run_host("tmux", "launch", "sess", spec=spec)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        respawn = [c for c in self.call_for("tmux") if c[0] == "respawn-pane"][0]
        self.assertIn("--allowedTools", respawn)
        self.assertTrue(
            any("notify" in arg for arg in respawn if arg.startswith("Bash(")), respawn
        )
        with open(os.path.join(self.work, ".claude.json"), encoding="utf-8") as handle:
            config = json.load(handle)
        self.assertTrue(
            config["projects"][os.path.realpath(spec["cwd"])]["hasTrustDialogAccepted"]
        )

    def test_pi_launch_never_writes_claude_trust(self):
        proc = self.run_host("tmux", "launch", "sess", spec=self.spec())
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.work, ".claude.json")))

    def test_notify_pastes_and_submits(self):
        proc = self.run_host("tmux", "notify", "%9", "hi\nthere")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        calls = self.call_for("tmux")
        self.assertEqual(calls[0][0], "load-buffer")
        self.assertIn("-t", calls[1])
        self.assertEqual(calls[1][calls[1].index("-t") + 1], "%9")
        self.assertEqual(calls[2], ["send-keys", "-t", "%9", "Enter"])

    def test_close_kills_the_window(self):
        proc = self.run_host("tmux", "close", "@7")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.call_for("tmux")[0], ["kill-window", "-t", "@7"])


class HerdrHostTest(HostTest):
    def test_launch_targets_the_calling_workspace_not_the_focused_one(self):
        spec = self.spec()
        env = dict(self.env, HERDR_WORKSPACE_ID="7")
        proc = self.run_host("herdr", "launch", spec=spec, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = json.loads(proc.stdout)
        self.assertEqual(result["tab"], "1:1")
        self.assertEqual(result["pane"], "1-1")

        tab = self.call_for("herdr")[0]
        self.assertEqual(tab[:2], ["tab", "create"])
        self.assertEqual(tab[tab.index("--workspace") + 1], "7")
        self.assertEqual(tab[tab.index("--cwd") + 1], spec["cwd"])
        self.assertIn("--no-focus", tab)

        start = self.call_for("herdr")[1]
        self.assertEqual(start[:3], ["agent", "start", spec["name"]])
        self.assertEqual(start[start.index("--kind") + 1], "pi")
        self.assertEqual(start[start.index("--pane") + 1], "1-1")
        self.assertIn(spec["model"], start)

        prompt = self.call_for("herdr")[2]
        self.assertEqual(prompt[:3], ["agent", "prompt", spec["name"]])
        self.assertEqual(prompt[3], spec["prompt"])

    def test_claude_launch_allows_herdr_reporting(self):
        spec = self.spec(kind="claude", model="claude-code/sonnet", effort="low")
        env = dict(self.env, HERDR_WORKSPACE_ID="7")
        proc = self.run_host("herdr", "launch", spec=spec, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        start = self.call_for("herdr")[1]
        self.assertIn("--allowedTools", start)
        self.assertIn("Bash(herdr agent prompt *)", start)

    def test_claude_launch_trusts_the_directory(self):
        spec = self.spec(kind="claude", model="claude-code/sonnet", effort="low")
        os.makedirs(spec["cwd"], exist_ok=True)
        env = dict(self.env, HERDR_WORKSPACE_ID="7")
        proc = self.run_host("herdr", "launch", spec=spec, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        with open(os.path.join(self.work, ".claude.json"), encoding="utf-8") as handle:
            config = json.load(handle)
        self.assertTrue(
            config["projects"][os.path.realpath(spec["cwd"])]["hasTrustDialogAccepted"]
        )

    def test_notify_prompts_the_manager_agent(self):
        proc = self.run_host("herdr", "notify", "manager", "hello")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            self.call_for("herdr")[0], ["agent", "prompt", "manager", "hello"]
        )

    def test_launch_without_a_calling_workspace_is_refused(self):
        env = dict(self.env)
        env.pop("HERDR_WORKSPACE_ID", None)
        proc = self.run_host("herdr", "launch", spec=self.spec(), env=env)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("HERDR_WORKSPACE_ID", proc.stderr)
        self.assertEqual(self.call_for("herdr"), [])

    def test_a_failed_prompt_never_echoes_the_message(self):
        env = dict(self.env)
        env["PATH"] = os.pathsep.join([self.failing_cli("herdr"), env["PATH"]])
        proc = self.run_host("herdr", "notify", "manager", "SECRET MESSAGE", env=env)
        self.assertNotEqual(proc.returncode, 0)
        self.assertNotIn("SECRET MESSAGE", proc.stdout + proc.stderr)
        self.assertIn("herdr agent prompt failed: blocked", proc.stderr)

    def test_close_closes_the_tab(self):
        proc = self.run_host("herdr", "close", "1:1")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.call_for("herdr")[0], ["tab", "close", "1:1"])


class TmuxSandboxTest(unittest.TestCase):
    """The one real tmux exercise: a private server through scripts/tmux-sandbox."""

    def setUp(self):
        if not shutil.which("tmux"):
            self.skipTest("tmux not installed")
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.work = work.name

    def build_spec(self):
        repo = os.path.join(self.work, "repo")
        os.makedirs(repo)
        subprocess.run(["git", "-C", repo, "init", "-q"], check=True, capture_output=True)
        for name in ("tdd", "coding"):
            directory = os.path.join(repo, ".agents", "skills", name)
            os.makedirs(directory)
            with open(os.path.join(directory, "SKILL.md"), "w", encoding="utf-8") as handle:
                handle.write(f"---\nname: {name}\ndescription: test\n---\nbody\n")
        extension = os.path.join(repo, "host.md")
        with open(extension, "w", encoding="utf-8") as handle:
            handle.write("# host\n")
        argv = [
            "subagent.py", "--stage", "build", "--item", "wi-sbx", "--cwd", repo,
            "--extension", extension, "--manager", "%0", "--dry-run", "sandbox brief",
        ]
        # Keep this fake-pi transport fixture independent of the default model.
        with mock.patch.dict(
            subagent.MODELS,
            {"builder": ("github-copilot/gpt-6.1-sol", "Sandbox Pi fixture.")},
        ):
            return prepare_spec(argv)

    def test_launch_runs_through_a_private_tmux_server(self):
        spec = self.build_spec()
        fake_bin = os.path.join(self.work, "fake")
        os.makedirs(fake_bin)
        pi = os.path.join(fake_bin, "pi")
        with open(pi, "w", encoding="utf-8") as handle:
            handle.write('#!/bin/sh\nprintf "%s\\n" "$@" > "$OUT/pi-args"\nsleep 5\n')
        os.chmod(pi, 0o755)

        out = os.path.join(self.work, "out")
        os.makedirs(out)
        host = os.path.join(SKILL, "extensions", "tmux", "host.py")
        script = (
            "tmux -f /dev/null new-session -d -s subagent-sandbox\n"
            'printf "%s" "$SPEC" | python3 "$HOST" launch subagent-sandbox'
        )
        env = dict(os.environ)
        env.update(
            PATH=os.pathsep.join([fake_bin, os.environ.get("PATH", "")]),
            SPEC=json.dumps(spec),
            HOST=host,
            OUT=out,
            HOME=self.work,
        )
        env.pop("TYPESAFE_API_KEY", None)
        proc = subprocess.run(
            [os.path.join(REPO, "scripts", "tmux-sandbox"), "bash", "-c", script],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        with open(os.path.join(out, "pi-args"), encoding="utf-8") as handle:
            delivered = handle.read()
        self.assertIn(spec["name"], delivered)
        self.assertIn(spec["model"], delivered)
        self.assertIn("sandbox brief", delivered)
        self.assertIn("You are", delivered)


class SharedLaunchTest(unittest.TestCase):
    """The launch mechanics tmux and herdr share, against a fixture HOME.

    HOME points inside a temp dir, so the real ~/.claude.json is never read or
    written.
    """

    def setUp(self):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.work = work.name
        self.home = os.path.join(self.work, "home")
        os.makedirs(self.home)
        self.cwd = os.path.join(self.work, "repo")
        os.makedirs(self.cwd)
        env = mock.patch.dict(os.environ, {"HOME": self.home})
        env.start()
        self.addCleanup(env.stop)

    def trust_config(self):
        with open(os.path.join(self.home, ".claude.json"), encoding="utf-8") as handle:
            return json.load(handle)

    def test_trust_pre_accepts_only_the_launched_directory(self):
        host_launch.trust_claude_dir(self.cwd)
        self.assertEqual(
            self.trust_config(),
            {
                "projects": {
                    os.path.realpath(self.cwd): {"hasTrustDialogAccepted": True}
                }
            },
        )

    def test_an_existing_config_keeps_its_other_entries(self):
        other = os.path.join(self.work, "other")
        with open(os.path.join(self.home, ".claude.json"), "w", encoding="utf-8") as handle:
            json.dump(
                {"projects": {os.path.realpath(other): {"hasTrustDialogAccepted": True}}},
                handle,
            )
        host_launch.trust_claude_dir(self.cwd)
        self.assertEqual(
            sorted(self.trust_config()["projects"]),
            sorted([os.path.realpath(other), os.path.realpath(self.cwd)]),
        )

    def test_an_unreadable_config_is_skipped_with_a_warning(self):
        path = os.path.join(self.home, ".claude.json")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("not json")
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            host_launch.trust_claude_dir(self.cwd)
        self.assertIn("skipping trust", stderr.getvalue())
        with open(path, encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "not json")

    def test_without_effort_drops_the_flag_only_on_a_level_error(self):
        cases = [
            (
                "claude",
                ["--model", "sonnet", "--effort", "low"],
                "error: unsupported effort level: low",
                ["--model", "sonnet"],
            ),
            (
                "pi",
                ["--model", "x", "--thinking", "high"],
                "error: bad thinking level",
                ["--model", "x"],
            ),
            ("pi", ["--model", "x", "--thinking", "high"], "no such flag: --thinking", None),
            ("pi", ["--model", "x"], "error: thinking level", None),
        ]
        for kind, argv, view, expected in cases:
            with self.subTest(kind=kind, view=view):
                self.assertEqual(host_launch.without_effort(argv, kind, view), expected)


if __name__ == "__main__":
    unittest.main()

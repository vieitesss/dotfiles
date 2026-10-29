#!/usr/bin/env python3
"""Tests for the session-host extensions.

Fake `paseo`, `herdr`, `tmux`, and `rex` executables stand in for the real
CLIs and record every call, so nothing is launched. The one real tmux exercise
runs through scripts/tmux-sandbox, and the real Rex exercise through a private
Rex server, never the live ones.
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
import time
import unittest
from unittest import mock

import subagent
from test_support import prepare_spec

BUILDER_MODEL = subagent.MODELS["builder"][0]

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
if name == "paseo" and args[:2] == ["workspace", "ls"]:
    print(os.environ.get("FAKE_WORKSPACES", "[]"))
elif name == "paseo" and args[:2] == ["project", "ls"]:
    print(os.environ.get("FAKE_PROJECTS", "[]"))
elif name == "paseo" and args[:2] == ["workspace", "create"]:
    print(json.dumps({"workspaceId": "wks-new",
                      "cwd": args[args.index("--path") + 1]}))
elif name == "paseo" and args[:1] == ["run"]:
    print(json.dumps({"agentId": "agent-42"}))
elif name == "herdr" and args[:2] == ["tab", "create"]:
    print(json.dumps({"result": {"root_pane": {"pane_id": "1-1"},
                                 "tab": {"tab_id": "1:1"}}}))
elif name == "herdr" and args[:2] == ["pane", "process-info"]:
    print(json.dumps({"result": {"process_info": {
        "shell_pid": int(os.environ["FAKE_MANAGER_PID"])}}}))
elif name == "tmux":
    if args[:1] == ["has-session"] and os.environ.get("FAKE_NO_SESSION"):
        sys.exit(1)
    elif args[:1] == ["new-window"]:
        print("@1 %1")
    elif args[:1] == ["display-message"] and "#{pane_pid}" in args:
        print(os.environ["FAKE_MANAGER_PID"])
    elif args[:1] == ["display-message"]:
        print("%1 0")
elif name == "recado" and args[:1] == ["send"]:
    if os.environ.get("FAKE_RECADO_FAILURE"):
        print("recado delivery failed", file=sys.stderr)
        sys.exit(1)
    print("sent-1")
elif name == "rex":
    if args[:2] == ["window", "new"]:
        print(json.dumps({"window_id": "window:w1", "block_ids": ["block:b1"]}))
    elif args[:2] == ["block", "call"] and args[-1] == "process":
        block = args[args.index("-b") + 1]
        pid = int(os.environ["FAKE_MANAGER_PID"]) if block != "block:b1" else 99999
        print(json.dumps({"last_exit": None, "child": {"pid": pid}}))
'''


class HostTest(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.work = work.name
        self.bin = os.path.join(self.work, "bin")
        os.makedirs(self.bin)
        self.log = os.path.join(self.work, "log")
        for name in ("paseo", "herdr", "tmux", "rex", "recado"):
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
            FAKE_MANAGER_PID=str(os.getpid()),
            XDG_STATE_HOME=os.path.join(self.work, "state"),
        )
        self.env.pop("TYPESAFE_API_KEY", None)
        self.env.pop("PASEO_AGENT_ID", None)

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

    def actions_for(self, name):
        """call_for minus the read-only Manager-pane checks."""
        checks = (["pane", "process-info"], ["block", "call"])
        return [
            args for args in self.call_for(name)
            if not any(args[:len(c)] == c for c in checks)
            and not (args[:1] == ["display-message"] and "#{pane_pid}" in args)
        ]

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

    def spec(self, kind="pi", model=BUILDER_MODEL, effort="high"):
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
            "recado_bin_dir": "/custom/bin",
            "model": model,
            "effort": effort if kind != "claude" else "low",
            "role": role,
            "skills": {},
            "engine": engine,
            "prompt": f"{role}\n\nFIRST LINE\nsecond line of brief",
        }


class RetiredMessagingTest(HostTest):
    def test_hosts_reject_retired_messaging_commands(self):
        for host, command in (("paseo", "send"), ("paseo", "pending"),
                              ("herdr", "notify"), ("tmux", "notify"), ("rex", "notify")):
            with self.subTest(host=host, command=command):
                args = () if command == "pending" else ("target", "message")
                proc = self.run_host(host, command, *args)
                self.assertNotEqual(proc.returncode, 0)
                self.assertEqual(self.calls(), [])


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

    def test_remote_paseo_delivers_prepared_recado_commands(self):
        cwd = os.path.join(self.work, "rpi-checkout")
        os.makedirs(cwd)
        extension = os.path.join(SKILL, "extensions", "paseo-remote.md")
        manager = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        upstream = "recado+upstream://mac.local/manager-1"
        env = dict(self.env, TMUX_PANE="%36")
        env.pop("PASEO_AGENT_ID", None)
        with mock.patch.dict(os.environ, env, clear=True):
            with mock.patch.object(subagent, "stage_skills", return_value={}):
                spec = prepare_spec([
                    "subagent.py", "--stage", "diagnose", "--item", "remote",
                    "--cwd", cwd, "--extension", extension, "--manager", manager,
                    "--manager-recado", upstream, "--dry-run", "remote brief",
                ])
        proc = self.run_host("paseo", "launch", spec=spec, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        delivered = self.run_call()[-1]
        self.assertEqual(delivered, spec["prompt"])
        self.assertIn(f"recado send {upstream}", delivered)
        self.assertIn(f"recado ask {upstream}", delivered)
        self.assertNotIn("%36", delivered)

    def test_pi_launch_uses_the_pi_provider_and_full_model(self):
        spec = self.spec()
        spec["recado_bin_dir"] = "/custom/recado bin"
        env = dict(self.env, TYPESAFE_API_KEY="manager-secret")
        proc = self.run_host("paseo", "launch", spec=spec, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("manager-secret", json.dumps(self.calls()))
        self.assertEqual(json.loads(proc.stdout)["agentId"], "agent-42")

        argv = self.run_call()
        self.assertEqual(argv[:3], ["run", "--background", "--json"])
        self.assertIn("--provider", argv)
        self.assertEqual(argv[argv.index("--provider") + 1], "pi")
        self.assertEqual(argv[argv.index("--model") + 1], spec["model"])
        self.assertEqual(argv[argv.index("--thinking") + 1], "high")
        self.assertEqual(argv[argv.index("--cwd") + 1], spec["cwd"])
        self.assertEqual(argv[argv.index("--title") + 1], spec["name"])
        self.assertIn("RECADO_ADDR=" + spec["name"], argv)
        self.assertIn("PATH=/custom/recado bin:" + self.env["PATH"], argv)
        self.assertNotIn("--mode", argv)
        self.assertEqual(argv[-1], spec["prompt"])

    def test_claude_launch_uses_the_claude_provider_and_alias(self):
        spec = self.spec(kind="claude", model="claude-code/sonnet", effort="low")
        proc = self.run_host("paseo", "launch", spec=spec)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        argv = self.run_call()
        self.assertEqual(argv[argv.index("--provider") + 1], "claude")
        self.assertEqual(argv[argv.index("--model") + 1], "sonnet")
        self.assertEqual(argv[argv.index("--thinking") + 1], "low")
        self.assertEqual(argv[argv.index("--mode") + 1], "auto")
        self.assertNotIn("bypassPermissions", argv)

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

    def test_a_worktree_without_a_workspace_joins_the_callers_project(self):
        # run --new-workspace local would register the worktree, its own git
        # root, as a project of its own.
        spec = self.spec()
        caller = os.path.join(self.work, "elsewhere")
        env = dict(
            self.env,
            PASEO_AGENT_CWD=caller,
            FAKE_WORKSPACES=json.dumps(
                [{"workspaceId": "wks-1", "project": "app", "cwd": caller}]
            ),
            FAKE_PROJECTS=json.dumps(
                [
                    {"projectId": "prj-other", "name": "other"},
                    {"projectId": "prj-app", "name": "app"},
                ]
            ),
        )
        proc = self.run_host("paseo", "launch", spec=spec, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        create = [
            args for args in self.call_for("paseo")
            if args[:2] == ["workspace", "create"]
        ][0]
        self.assertEqual(create[create.index("--project") + 1], "prj-app")
        self.assertEqual(create[create.index("--path") + 1], spec["cwd"])
        self.assertEqual(create[create.index("--isolation") + 1], "local")
        self.assertEqual(create[create.index("--title") + 1], spec["name"])
        argv = self.run_call()
        self.assertEqual(argv[argv.index("--workspace") + 1], "wks-new")
        self.assertNotIn("--new-workspace", argv)
        self.assertNotIn("--cwd", argv)

    def test_an_ambiguous_caller_project_falls_back_to_a_local_workspace(self):
        spec = self.spec()
        caller = os.path.join(self.work, "elsewhere")
        env = dict(
            self.env,
            PASEO_AGENT_CWD=caller,
            FAKE_WORKSPACES=json.dumps(
                [{"workspaceId": "wks-1", "project": "app", "cwd": caller}]
            ),
            FAKE_PROJECTS=json.dumps(
                [
                    {"projectId": "prj-a", "name": "app"},
                    {"projectId": "prj-b", "name": "app"},
                ]
            ),
        )
        proc = self.run_host("paseo", "launch", spec=spec, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            [a for a in self.call_for("paseo") if a[:2] == ["workspace", "create"]],
            [],
        )
        argv = self.run_call()
        self.assertEqual(argv[argv.index("--new-workspace") + 1], "local")

    def test_a_worktree_without_a_caller_project_mints_a_local_one(self):
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
        self.assertIn("as its own project", proc.stderr)

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
        self.assertFalse(os.path.exists(os.path.join(self.work, ".claude.json")))

        window = self.actions_for("tmux")[0]
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
        self.assertIn("Bash(recado send *)", respawn)
        self.assertIn("Bash(recado ask *)", respawn)
        with open(os.path.join(self.work, ".claude.json"), encoding="utf-8") as handle:
            config = json.load(handle)
        self.assertTrue(
            config["projects"][os.path.realpath(spec["cwd"])]["hasTrustDialogAccepted"]
        )

    def test_close_kills_the_window(self):
        proc = self.run_host("tmux", "close", "@7")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.call_for("tmux")[0], ["kill-window", "-t", "@7"])


class HerdrHostTest(HostTest):
    def test_launch_targets_the_calling_workspace_not_the_focused_one(self):
        spec = self.spec()
        spec["recado_bin_dir"] = "/custom/recado bin"
        env = dict(self.env, HERDR_WORKSPACE_ID="7", TYPESAFE_API_KEY="manager-secret")
        proc = self.run_host("herdr", "launch", spec=spec, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertNotIn("manager-secret", json.dumps(self.calls()))
        result = json.loads(proc.stdout)
        self.assertEqual(result["tab"], "1:1")
        self.assertEqual(result["pane"], "1-1")

        tab = self.actions_for("herdr")[0]
        self.assertEqual(tab[:2], ["tab", "create"])
        self.assertEqual(tab[tab.index("--workspace") + 1], "7")
        self.assertEqual(tab[tab.index("--cwd") + 1], spec["cwd"])
        self.assertIn("RECADO_ADDR=" + spec["name"], tab)
        self.assertIn("PATH=/custom/recado bin:" + self.env["PATH"], tab)
        self.assertIn("--no-focus", tab)

        start = self.actions_for("herdr")[1]
        self.assertEqual(start[:3], ["agent", "start", spec["name"]])
        self.assertEqual(start[start.index("--kind") + 1], "pi")
        self.assertEqual(start[start.index("--pane") + 1], "1-1")
        self.assertIn(spec["model"], start)

        prompt = self.actions_for("herdr")[2]
        self.assertEqual(prompt[:3], ["agent", "prompt", spec["name"]])
        self.assertEqual(prompt[3], spec["prompt"])

    def test_claude_launch_allows_reporting_and_trusts_the_directory(self):
        spec = self.spec(kind="claude", model="claude-code/sonnet", effort="low")
        spec["recado_bin_dir"] = "/custom/bin"
        os.makedirs(spec["cwd"], exist_ok=True)
        env = dict(self.env, HERDR_WORKSPACE_ID="7")
        proc = self.run_host("herdr", "launch", spec=spec, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        start = self.actions_for("herdr")[1]
        self.assertIn("--allowedTools", start)
        for command in ("recado send", "recado ask",
                        "/custom/bin/recado send", "/custom/bin/recado ask"):
            self.assertIn(f"Bash({command} *)", start)
        with open(os.path.join(self.work, ".claude.json"), encoding="utf-8") as handle:
            config = json.load(handle)
        self.assertTrue(
            config["projects"][os.path.realpath(spec["cwd"])]["hasTrustDialogAccepted"]
        )

    def test_launch_without_a_calling_workspace_is_refused(self):
        env = dict(self.env)
        env.pop("HERDR_WORKSPACE_ID", None)
        proc = self.run_host("herdr", "launch", spec=self.spec(), env=env)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("HERDR_WORKSPACE_ID", proc.stderr)
        self.assertEqual(self.actions_for("herdr"), [])

    def test_close_closes_the_tab(self):
        proc = self.run_host("herdr", "close", "1:1")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.call_for("herdr")[0], ["tab", "close", "1:1"])


class RexHostTest(HostTest):
    def setUp(self):
        super().setUp()
        self.env["REX_SESSION"] = "session:s1"

    def test_launch_opens_a_background_window_in_the_calling_session(self):
        spec = self.spec()
        proc = self.run_host("rex", "launch", spec=spec)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = json.loads(proc.stdout)
        self.assertEqual(result["window"], "window:w1")
        self.assertEqual(result["block"], "block:b1")
        self.assertEqual(result["session"], "session:s1")

        window = self.actions_for("rex")[0]
        self.assertEqual(window[:2], ["window", "new"])
        self.assertEqual(window[window.index("-s") + 1], "session:s1")
        self.assertEqual(window[window.index("-c") + 1], spec["cwd"])
        for flag in ("--focus=false", "--keep-open", "--shell=none"):
            self.assertIn(flag, window)

    def test_an_explicit_session_wins_over_the_calling_one(self):
        proc = self.run_host("rex", "launch", "session:other", spec=self.spec())
        self.assertEqual(proc.returncode, 0, proc.stderr)
        window = self.actions_for("rex")[0]
        self.assertEqual(window[window.index("-s") + 1], "session:other")

    def test_claude_launch_allows_reporting_and_trusts_the_directory(self):
        spec = self.spec(kind="claude", model="claude-code/sonnet", effort="low")
        os.makedirs(spec["cwd"], exist_ok=True)
        proc = self.run_host("rex", "launch", spec=spec)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        window = self.actions_for("rex")[0]
        self.assertIn("--allowedTools", window)
        self.assertIn("Bash(recado send *)", window)
        self.assertIn("Bash(recado ask *)", window)
        with open(os.path.join(self.work, ".claude.json"), encoding="utf-8") as handle:
            config = json.load(handle)
        self.assertTrue(
            config["projects"][os.path.realpath(spec["cwd"])]["hasTrustDialogAccepted"]
        )

    def test_launch_without_a_calling_session_is_refused(self):
        env = dict(self.env)
        env.pop("REX_SESSION")
        proc = self.run_host("rex", "launch", spec=self.spec(), env=env)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("REX_SESSION", proc.stderr)
        self.assertEqual(self.actions_for("rex"), [])

class RemoteRexHostTest(HostTest):
    """A Rex Manager whose Subagent runs in tmux on another machine.

    A fake ssh runs the remote command locally, with this checkout installed
    at the fixture HOME's ~/.agents/skills/subagents, so both sides use the
    fake CLIs and the same fixture state directory.
    """

    def setUp(self):
        super().setUp()
        skills = os.path.join(self.work, ".agents", "skills")
        os.makedirs(skills)
        os.symlink(SKILL, os.path.join(skills, "subagents"))
        ssh = os.path.join(self.bin, "ssh")
        with open(ssh, "w", encoding="utf-8") as handle:
            handle.write(
                '#!/bin/sh\nfor arg; do last=$arg; done\nexec sh -c "$last"\n'
            )
        os.chmod(ssh, 0o755)
        self.env["REX_SESSION"] = "session:s1"

    def test_remote_launch_starts_tmux_and_sends_recado_kickoff(self):
        env = dict(self.env, FAKE_NO_SESSION="1")
        spec = self.spec(kind="claude", model="claude-code/sonnet", effort="low")
        spec["recado_bin_dir"] = "/remote/bin"
        os.makedirs(spec["cwd"], exist_ok=True)
        proc = self.run_host("rex", "remote-launch", "rpi", spec=spec, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = json.loads(proc.stdout)
        self.assertEqual(result["machine"], "rpi")
        self.assertEqual(result["pane"], "%1")
        self.assertEqual(result["kickoff"], "sent-1")
        self.assertEqual(self.call_for("recado"), [[
            "send", "recado://rpi/subagent-build-1",
            "Continue the brief; this opens the recado return route.",
        ]])

        tmux = self.actions_for("tmux")
        self.assertEqual(tmux[0], ["has-session", "-t", "=subagents"])
        self.assertEqual(tmux[1][:4], ["new-session", "-d", "-s", "subagents"])
        window = [c for c in tmux if c[0] == "new-window"][0]
        self.assertEqual(window[window.index("-t") + 1], "=subagents:")
        respawn = [c for c in tmux if c[0] == "respawn-pane"][0]
        self.assertTrue(any("recado send *)" in arg for arg in respawn), respawn)

    def test_remote_tmux_child_registers_under_its_spec_name(self):
        real_recado = shutil.which("recado")
        if not real_recado:
            self.skipTest("recado not installed")
        pi = os.path.join(self.bin, "pi")
        with open(pi, "w", encoding="utf-8") as handle:
            handle.write('#!/bin/sh\nprintf "%s" "$PATH" > "$HOME/child-path"\n'
                         'export RECADO_HARNESS=pi\n'
                         'exec "$REAL_RECADO" hook pi session-start --endpoint "$HOME/probe.sock" --json\n')
        os.chmod(pi, 0o755)
        state = os.path.join(self.work, "recado-state")
        env = dict(self.env, SHELL="/bin/sh", REAL_RECADO=real_recado,
                   RECADO_STATE_DIR=state, RECADO_ADDR="manager")
        spec = self.spec()
        spec["recado_bin_dir"] = "/recado bin"
        os.makedirs(spec["cwd"], exist_ok=True)
        proc = self.run_host("rex", "remote-launch", "rpi", spec=spec, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        respawn = next(c for c in self.call_for("tmux") if c[0] == "respawn-pane")
        command = respawn[respawn.index("--") + 1:]
        registered = subprocess.run(command, env=env, text=True, capture_output=True)
        self.assertEqual(registered.returncode, 0, registered.stderr)
        agents = subprocess.run([real_recado, "agents", "--json"], env=env,
                                text=True, capture_output=True, check=True)
        self.assertEqual([a["id"] for a in json.loads(agents.stdout)["agents"]], [spec["name"]])
        with open(os.path.join(self.work, "child-path"), encoding="utf-8") as handle:
            self.assertTrue(handle.read().startswith("/recado bin:"))

    def test_remote_launch_refuses_a_block_this_manager_does_not_run_in(self):
        env = dict(self.env, FAKE_MANAGER_PID="99998")
        proc = self.run_host("rex", "remote-launch", "rpi", spec=self.spec(), env=env)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("not the pane this Manager runs in", proc.stderr)
        self.assertEqual(self.call_for("tmux"), [])

    def test_a_bad_ssh_host_is_refused(self):
        proc = self.run_host("rex", "remote-close", "-oProxyCommand=x", "@1")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("not an SSH host", proc.stderr)

    def test_remote_close_kills_the_remote_window(self):
        proc = self.run_host("rex", "remote-close", "rpi", "@1")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.call_for("tmux"), [["kill-window", "-t", "@1"]])

    def test_remote_launch_reports_the_window_when_kickoff_fails(self):
        env = dict(self.env, FAKE_RECADO_FAILURE="1")
        spec = self.spec()
        os.makedirs(spec["cwd"], exist_ok=True)
        proc = self.run_host("rex", "remote-launch", "rpi", spec=spec, env=env)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("recado delivery failed", proc.stderr)
        self.assertIn("@1", proc.stderr)
        self.assertIn("%1", proc.stderr)


class ManagerValidationTest(HostTest):
    def test_interactive_hosts_reject_other_panes_and_paseo_managers(self):
        for host in ("tmux", "herdr", "rex"):
            for extra, reason in (({"FAKE_MANAGER_PID": "99998"}, "not the pane this Manager runs in"),
                                  ({"PASEO_AGENT_ID": "agent"}, "Paseo agent")):
                with self.subTest(host=host, extra=extra):
                    if os.path.exists(self.log):
                        os.unlink(self.log)
                    env = dict(self.env, HERDR_WORKSPACE_ID="7", REX_SESSION="session:s1", **extra)
                    proc = self.run_host(host, "launch", spec=self.spec(), env=env)
                    self.assertEqual(proc.returncode, 2, proc.stderr)
                    self.assertIn(reason, proc.stderr)
                    self.assertEqual(self.actions_for(host), [])


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
        ), mock.patch.object(subagent, "recado_route", return_value=("recado", "recado://local/manager", "/bin")):
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
        # The launch runs inside pane %0, so %0 really is this Manager's pane.
        script = (
            "tmux -f /dev/null new-session -d -s subagent-sandbox "
            "'printf \"%s\" \"$SPEC\" | python3 \"$HOST\" launch subagent-sandbox "
            ">\"$OUT/launch\" 2>&1; echo $? >\"$OUT/rc\"; sleep 30'\n"
            'i=0; while [ ! -s "$OUT/rc" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done\n'
            'cat "$OUT/launch" >&2; exit "$(cat "$OUT/rc")"'
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
        env.pop("PASEO_AGENT_ID", None)
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


REX_DRIVER = """import json, os, subprocess, sys
work, server, host = sys.argv[1:4]
os.environ["REX_SERVER"] = server  # never fall back to the live server
with open(os.path.join(work, "spec.json"), encoding="utf-8") as handle:
    spec = json.load(handle)
spec["manager"] = os.environ["REX_BLOCK"]
proc = subprocess.run([sys.executable, host, "launch"], input=json.dumps(spec),
                      capture_output=True, text=True)
for name, text in (("launch", proc.stderr), ("result", proc.stdout)):
    with open(os.path.join(work, name), "w", encoding="utf-8") as handle:
        handle.write(text)
with open(os.path.join(work, "rc"), "w", encoding="utf-8") as handle:
    handle.write(str(proc.returncode))
"""


class RexSandboxTest(unittest.TestCase):
    """The one real Rex exercise: a private server this test starts and stops.

    rex is found as host.py finds it (PATH, then REX_BIN_DIR); without it the
    test is skipped. Every rex call names the private socket, so the live
    server is never touched.
    """

    def setUp(self):
        directory = os.environ.get("REX_BIN_DIR", "")
        self.rex = shutil.which("rex") or (
            os.path.join(directory, "rex")
            if directory and os.access(os.path.join(directory, "rex"), os.X_OK)
            else None
        )
        if not self.rex:
            self.skipTest("rex not installed")
        # A short path: unix socket paths are capped near 104 bytes.
        self.work = tempfile.mkdtemp(prefix="rexsb-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.work, True)
        self.server = f"unix://{self.work}/s.sock"

    build_spec = TmuxSandboxTest.build_spec

    def start_server(self, env):
        log = open(os.path.join(self.work, "server.log"), "w", encoding="utf-8")
        self.addCleanup(log.close)
        server = subprocess.Popen(
            [self.rex, "server", "run", "--listen", self.server,
             "--state-dir", os.path.join(self.work, "state"),
             "--config", os.path.join(self.work, "none.lua")],
            stdout=log, stderr=log, env=env,
        )
        self.addCleanup(server.wait)
        self.addCleanup(server.terminate)
        for _ in range(100):
            if self.rex_cli("session", "list").returncode == 0:
                return
            time.sleep(0.1)
        self.fail("private rex server never came up")

    def rex_cli(self, *args):
        return subprocess.run(
            [self.rex, "-S", self.server, "--autostart=false", *args],
            capture_output=True, text=True,
        )

    def test_launch_runs_through_a_private_rex_server(self):
        spec = self.build_spec()
        with open(os.path.join(self.work, "spec.json"), "w", encoding="utf-8") as handle:
            json.dump(spec, handle)
        fake_bin = os.path.join(self.work, "fake")
        os.makedirs(fake_bin)
        with open(os.path.join(fake_bin, "pi"), "w", encoding="utf-8") as handle:
            handle.write(f'#!/bin/sh\nprintf "%s\\n" "$@" > {self.work}/pi-args\nsleep 30\n')
        os.chmod(os.path.join(fake_bin, "pi"), 0o755)
        driver = os.path.join(self.work, "driver.py")
        with open(driver, "w", encoding="utf-8") as handle:
            handle.write(REX_DRIVER)

        env = dict(os.environ)
        env.update(
            PATH=os.pathsep.join([fake_bin, os.environ.get("PATH", "")]),
            REX_SERVER=self.server,
            XDG_STATE_HOME=os.path.join(self.work, "xdg"),
        )
        for var in ("TYPESAFE_API_KEY", "PASEO_AGENT_ID", "TMUX", "HERDR_WORKSPACE_ID"):
            env.pop(var, None)
        self.start_server(env)

        host = os.path.join(SKILL, "extensions", "rex", "host.py")
        # The launch runs inside the Manager block, so it really is the Manager's.
        created = self.rex_cli(
            "new", "manager", "-c", self.work, "--keep-open", "--shell=none", "--json",
            "--", sys.executable, driver, self.work, self.server, host,
        )
        self.assertEqual(created.returncode, 0, created.stderr)
        rc = os.path.join(self.work, "rc")
        for _ in range(200):
            if os.path.exists(rc) and os.path.getsize(rc):
                break
            time.sleep(0.1)
        with open(os.path.join(self.work, "launch"), encoding="utf-8") as handle:
            output = handle.read()
        with open(rc, encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "0", output)
        with open(os.path.join(self.work, "pi-args"), encoding="utf-8") as handle:
            delivered = handle.read()
        self.assertIn(spec["model"], delivered)
        self.assertIn("sandbox brief", delivered)

        with open(os.path.join(self.work, "result"), encoding="utf-8") as handle:
            result = json.load(handle)
        self.assertEqual(result["host"], "rex")
        proc = subprocess.run(
            [sys.executable, host, "close", result["window"]],
            capture_output=True, text=True, env=env,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)


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

    def test_child_delivers_only_allowlisted_secret_via_private_temporary_file(self):
        engine = os.path.join(self.work, "engine")
        output = os.path.join(self.work, "child.json")
        with open(engine, "w", encoding="utf-8") as handle:
            handle.write('#!/usr/bin/env python3\nimport json, os, sys\n'
                         'json.dump({"secret": os.environ.get("TYPESAFE_API_KEY"), '
                         '"other": os.environ.get("OTHER_SECRET"), '
                         '"name": os.environ.get("RECADO_ADDR"), "path": os.environ["PATH"], '
                         '"args": sys.argv[1:]}, open(os.environ["OUT"], "w"))\n')
        os.chmod(engine, 0o755)
        secret = "secret ' $ \n value"
        with mock.patch.dict(os.environ, {"TYPESAFE_API_KEY": secret, "OTHER_SECRET": "do not pass", "SHELL": "/bin/sh"}):
            with mock.patch.object(host_launch.subprocess, "Popen"):
                command, (prompt_file, env_file) = host_launch.child_command(
                    "subagent-test", "brief\nnext line", engine, ["--model", "example"], "/recado bin"
                )
        self.addCleanup(host_launch.remove_temp, prompt_file, env_file)
        self.assertEqual(os.stat(env_file).st_mode & 0o777, 0o600)
        self.assertNotIn(secret, " ".join(command))
        server_env = {"PATH": os.environ["PATH"], "HOME": self.home, "OUT": output}
        proc = subprocess.run(command, env=server_env, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        with open(output, encoding="utf-8") as handle:
            delivered = json.load(handle)
        self.assertEqual(delivered["secret"], secret)
        self.assertIsNone(delivered["other"])
        self.assertEqual(delivered["name"], "subagent-test")
        self.assertTrue(delivered["path"].startswith("/recado bin:"))
        self.assertEqual(delivered["args"], ["--model", "example", "--", "brief\nnext line"])
        self.assertFalse(os.path.exists(prompt_file))
        self.assertFalse(os.path.exists(env_file))

    def test_child_cleans_both_files_if_sweeper_cannot_start(self):
        with mock.patch.object(host_launch.tempfile, "tempdir", self.work):
            with mock.patch.object(host_launch.subprocess, "Popen", side_effect=OSError("failed")):
                with self.assertRaises(OSError):
                    host_launch.child_command("subagent-test", "brief", "pi", [])
        self.assertFalse(any(name.startswith(("subagent-test-", "subagent-env-"))
                             for name in os.listdir(self.work)))

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

#!/usr/bin/env python3
"""Tests for the Rex host extension.

Fake `rex`, `recado` and `ssh` executables stand in for the real CLIs and
record every call, so nothing is launched. The one real Rex exercise runs
through a private Rex server, never the live one.
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
if name == "rex":
    # The host must never let rex start a server of its own.
    if args[:1] != ["--autostart=false"]:
        sys.exit("rex called without --autostart=false")
    args = args[1:]
log = os.environ["FAKE_LOG"]
with open(log, "a", encoding="utf-8") as handle:
    handle.write(json.dumps([name, args]) + "\\n")
if name == "recado" and args[:2] == ["machine", "ls"]:
    print(json.dumps({"machines": [{"name": "rpi", "kind": "ssh", "target": "pi-ssh"}]}))
elif name == "recado" and args[:1] == ["whoami"]:
    print(json.dumps({"address": "recado://local/manager-1", "agent": "manager-1"}))
elif name == "recado" and args[:1] == ["send"]:
    if os.environ.get("FAKE_RECADO_FAILURE"):
        print("recado delivery failed", file=sys.stderr)
        sys.exit(1)
    print("sent-1")
elif name == "rex":
    if args[:2] == ["window", "new"]:
        print(json.dumps({"window_id": "window:w1", "block_ids": ["block:b1"]}))
    elif args[:1] == ["ls"]:
        print(os.environ.get("FAKE_SESSIONS", '{"sessions": []}'))
    elif args[:1] == ["new"]:
        print(json.dumps({"session_id": "session:new"}))
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
        for name in ("rex", "recado"):
            path = os.path.join(self.bin, name)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(FAKE_CLI)
            os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP)
        self.env = dict(os.environ)
        self.env.update(
            FAKE_LOG=self.log,
            PATH=os.pathsep.join([self.bin, os.environ.get("PATH", "")]),
            HOME=self.work,
            FAKE_MANAGER_PID=str(os.getpid()),
            XDG_STATE_HOME=os.path.join(self.work, "state"),
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

    def actions_for(self, name):
        """call_for minus the read-only Manager-block checks."""
        return [args for args in self.call_for(name) if args[:2] != ["block", "call"]]

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
            "extension": os.path.join(SKILL, "extensions", "rex.md"),
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
        for command in ("notify", "send", "remote-close"):
            with self.subTest(command=command):
                proc = self.run_host("rex", command, "target", "message", "extra")
                self.assertNotEqual(proc.returncode, 0)
                self.assertEqual(self.calls(), [])


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

class ManagerValidationTest(HostTest):
    def test_launch_rejects_a_block_this_manager_does_not_run_in(self):
        env = dict(self.env, FAKE_MANAGER_PID="99998", REX_SESSION="session:s1")
        proc = self.run_host("rex", "launch", spec=self.spec(), env=env)
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assertIn("not the pane this Manager runs in", proc.stderr)
        self.assertEqual(self.actions_for("rex"), [])


class RemoteRexHostTest(HostTest):
    """A Manager launching a Stage on another Rex host.

    A fake ssh runs the remote script locally. The fixture HOME holds a fake
    ~/.agents/skills/subagents whose subagent.py records its argv and brief
    and prints a spec, beside the real Rex host helper.
    """

    BRIEF = "Line one with 'quotes' and $HOME\nline two `ticks`\n"

    def setUp(self):
        super().setUp()
        remote = os.path.join(self.work, ".agents", "skills", "subagents")
        os.makedirs(os.path.join(remote, "scripts"))
        os.makedirs(os.path.join(remote, "extensions"))
        for name in ("rex", "host_launch.py", "rex.md"):
            os.symlink(os.path.join(EXTENSIONS, name), os.path.join(remote, "extensions", name))
        spec = self.spec()
        os.makedirs(spec["cwd"], exist_ok=True)
        with open(os.path.join(remote, "scripts", "subagent.py"), "w", encoding="utf-8") as handle:
            handle.write(
                "import json, os, sys\n"
                "with open(os.path.join(os.environ['HOME'], 'prep.json'), 'w') as h:\n"
                "    json.dump(sys.argv[1:], h)\n"
                f"print(json.dumps({spec!r}))\n"
            )
        self.write_bin("ssh", '#!/bin/sh\nprintf "%s\\n" "$5" > "$HOME/ssh-target"\n'
                              'for arg; do last=$arg; done\nexec sh -c "$last"\n')
        self.env.update(REX_SESSION="session:s1", REX_BLOCK="block:manager")

    def write_bin(self, name, body):
        path = os.path.join(self.bin, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(body)
        os.chmod(path, 0o755)

    def remote_launch(self, *args, env=None):
        command = [sys.executable, os.path.join(EXTENSIONS, "rex", "host.py"),
                   "remote-launch", *args, "--stage", "build", "--item", "wi", "--cwd", "/remote/dir"]
        return subprocess.run(command, input=self.BRIEF, capture_output=True,
                              text=True, env=env or self.env)

    def test_prepares_and_launches_on_the_host_then_opens_the_return_route(self):
        proc = self.remote_launch("rpi")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = json.loads(proc.stdout)
        self.assertEqual(result["machine"], "rpi")
        self.assertEqual(result["window"], "window:w1")
        self.assertEqual(result["kickoff"], "sent-1")
        with open(os.path.join(self.work, "ssh-target"), encoding="utf-8") as handle:
            self.assertEqual(handle.read().strip(), "pi-ssh")

        with open(os.path.join(self.work, "prep.json"), encoding="utf-8") as handle:
            prep = json.load(handle)
        self.assertEqual(prep[-1], self.BRIEF.rstrip("\n"))
        self.assertEqual(prep[:6], ["--stage", "build", "--item", "wi", "--cwd", "/remote/dir"])
        self.assertEqual(prep[prep.index("--extension") + 1],
                         os.path.join(self.work, ".agents/skills/subagents/extensions/rex.md"))
        self.assertEqual(prep[prep.index("--manager") + 1], "block:manager")
        self.assertRegex(prep[prep.index("--manager-recado") + 1],
                         r"^recado\+upstream://[^/]+/manager-1$")

        rex = self.actions_for("rex")
        self.assertEqual(rex[1][:2], ["new", "subagents"])
        window = next(c for c in rex if c[:2] == ["window", "new"])
        self.assertEqual(window[window.index("-s") + 1], "session:new")
        self.assertEqual([c for c in self.call_for("recado") if c[:1] == ["send"]], [[
            "send", "recado://rpi/subagent-build-1",
            "Continue the brief; this opens the recado return route.",
        ]])

    def test_an_existing_session_on_the_host_is_reused(self):
        env = dict(self.env, FAKE_SESSIONS=json.dumps(
            {"sessions": [{"session_id": "session:work", "label": "work"}]}))
        proc = self.remote_launch("rpi", "--session", "work", env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rex = self.actions_for("rex")
        self.assertFalse([c for c in rex if c[:1] == ["new"]])
        window = next(c for c in rex if c[:2] == ["window", "new"])
        self.assertEqual(window[window.index("-s") + 1], "session:work")

    def test_a_block_this_manager_does_not_run_in_is_refused(self):
        env = dict(self.env, FAKE_MANAGER_PID="99998")
        proc = self.remote_launch("rpi", env=env)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("not the pane this Manager runs in", proc.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.work, "ssh-target")))

    def test_an_unknown_recado_machine_is_refused(self):
        proc = self.remote_launch("devbox")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("recado machine add devbox", proc.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.work, "ssh-target")))

    def test_a_failed_kickoff_reports_the_created_window(self):
        proc = self.remote_launch("rpi", env=dict(self.env, FAKE_RECADO_FAILURE="1"))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("recado delivery failed", proc.stderr)
        self.assertIn("window:w1", proc.stderr)

    def test_close_on_a_host_targets_its_server(self):
        proc = self.run_host("rex", "close", "window:w1", "rpi")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.call_for("rex"), [["-S", "rpi", "window", "close", "window:w1"]])


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
        fake_bin = os.path.join(self.work, "fake")
        os.makedirs(fake_bin)
        # The child's login shell rebuilds PATH; the recado bin dir is
        # prepended after it, so the fake pi wins over an installed one.
        spec["recado_bin_dir"] = fake_bin
        with open(os.path.join(self.work, "spec.json"), "w", encoding="utf-8") as handle:
            json.dump(spec, handle)
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
            # A login zsh rebuilds PATH and would run the real pi, not the fake.
            SHELL="/bin/sh",
        )
        for var in ("TYPESAFE_API_KEY", "TMUX"):
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
    """The Rex launch mechanics in host_launch, against a fixture HOME.

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

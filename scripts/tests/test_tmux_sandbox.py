#!/usr/bin/env python3
"""Regression fixtures for scripts/tmux-sandbox.

Every tmux server here is private: either it belongs to a tmux-sandbox state or
it is a sentinel created with an explicit -S socket under this test's own
temporary directory.  No fixture ever invokes tmux without a socket.

Run from the repository root:

    python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v
"""

import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUNNER = os.path.join(REPO, "scripts", "tmux-sandbox")
GUARD = os.path.join(REPO, "scripts", "tmux-guard")
FIXTURE_CONF = os.path.join(REPO, "scripts", "tests", "fixtures", "tmux-sandbox.conf")
TMUX = shutil.which("tmux")

STATE_RE = re.compile(r"^tmux-sandbox: state (.+)$", re.MULTILINE)


def clean_env(**extra):
    """This process's environment without the live tmux variables."""
    env = {key: value for key, value in os.environ.items() if key not in ("TMUX", "TMUX_PANE")}
    env.update(extra)
    return env


@unittest.skipUnless(TMUX, "tmux is required for the sandbox fixtures")
class SandboxTests(unittest.TestCase):
    def setUp(self):
        # States live directly under the real temporary directory, exactly as in
        # production, because a tmux socket path has a hard length limit.
        self.tmp = os.path.realpath(tempfile.gettempdir())
        self.created = []
        self.sentinel = None
        self.sentinel_sock = None
        self.sentinel_options = None
        self.addCleanup(self._cleanup)

    def _cleanup(self):
        if self.sentinel_sock and os.path.exists(self.sentinel_sock):
            self.run_tmux(self.sentinel_sock, "kill-server")
        for path in reversed(self.created):
            socket = os.path.join(path, "run", "tmux.sock")
            if os.path.exists(socket):
                self.run_tmux(socket, "kill-server")
            shutil.rmtree(path, ignore_errors=True)

    # -- helpers -----------------------------------------------------------

    def run_tmux(self, socket, *args):
        return subprocess.run(
            [TMUX, "-S", socket, "-f", FIXTURE_CONF, *args],
            env=clean_env(HOME=self.tmp),
            capture_output=True,
            text=True,
            check=False,
        )

    def run_runner(self, *args, env=None):
        return subprocess.run(
            [sys.executable, RUNNER, *args],
            env=clean_env() if env is None else env,
            capture_output=True,
            text=True,
            check=False,
        )

    def run_guard(self, command):
        return subprocess.run(
            [sys.executable, GUARD, "--", command],
            env=clean_env(),
            capture_output=True,
            text=True,
            check=False,
        )

    def state_from(self, proc):
        match = STATE_RE.search(proc.stderr)
        self.assertIsNotNone(match, proc.stderr)
        state = match.group(1)
        self.created.append(state)
        return state

    def start_sentinel(self):
        """Start an unrelated private server that the sandbox must never touch."""
        self.sentinel = os.path.realpath(
            tempfile.mkdtemp(prefix="tmux-sandbox-sentinel.", dir=self.tmp)
        )
        self.created.append(self.sentinel)
        os.chmod(self.sentinel, 0o700)
        self.sentinel_sock = os.path.join(self.sentinel, "sock")
        proc = self.run_tmux(
            self.sentinel_sock, "-f", FIXTURE_CONF, "new-session", "-d", "-s", "sentinel"
        )
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.run_tmux(self.sentinel_sock, "set-option", "-g", "@sentinel-keep", "yes")
        self.sentinel_options = self.run_tmux(
            self.sentinel_sock, "show-options", "-g"
        ).stdout
        return self.sentinel_sock

    def assert_sentinel_untouched(self):
        listed = self.run_tmux(self.sentinel_sock, "list-sessions")
        self.assertEqual(0, listed.returncode, listed.stderr)
        self.assertIn("sentinel", listed.stdout)
        options = self.run_tmux(self.sentinel_sock, "show-options", "-g")
        self.assertEqual(
            self.sentinel_options,
            options.stdout,
            "the sentinel server's options changed",
        )

    # -- state lifecycle ----------------------------------------------------

    def test_private_clients_never_load_user_config_or_home(self):
        socket = os.path.join(self.tmp, "fixture.sock")
        with mock.patch("subprocess.run") as run:
            self.run_tmux(socket, "new-session", "-d")
        args, kwargs = run.call_args
        self.assertEqual(
            [TMUX, "-S", socket, "-f", FIXTURE_CONF, "new-session", "-d"],
            args[0],
        )
        self.assertEqual(self.tmp, kwargs["env"]["HOME"])
        self.assertNotIn("TMUX", kwargs["env"])
        self.assertNotIn("TMUX_PANE", kwargs["env"])

    def test_new_creates_owned_state_the_guard_allows(self):
        state = self.run_runner("new").stdout.strip()
        self.created.append(state)
        self.assertTrue(os.path.isdir(state))
        self.assertEqual(0o700, stat.S_IMODE(os.stat(state).st_mode))
        state_file = os.path.join(state, "state.json")
        self.assertEqual(0o600, stat.S_IMODE(os.stat(state_file).st_mode))
        socket = self.run_runner("path", "--state", state).stdout.strip()
        self.assertTrue(socket.endswith("/run/tmux.sock"))

        guard = self.run_guard(f"tmux -S {socket} kill-server")
        self.assertEqual("allow\n", guard.stdout, guard.stderr)

        cleanup = self.run_runner("cleanup", "--state", state)
        self.assertEqual(0, cleanup.returncode, cleanup.stderr)
        self.assertFalse(os.path.exists(state))

    def test_run_reuses_an_owned_state(self):
        state = self.run_runner("new").stdout.strip()
        self.created.append(state)
        proc = self.run_runner("run", "--state", state, "--keep", "--", "sh", "-c", "true")
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertEqual(state, proc.stdout.strip())
        cleanup = self.run_runner("cleanup", "--state", state)
        self.assertEqual(0, cleanup.returncode, cleanup.stderr)

    def test_cleanup_kills_an_owned_running_server(self):
        state = self.run_runner("new").stdout.strip()
        self.created.append(state)
        socket = self.run_runner("path", "--state", state).stdout.strip()
        self.assertEqual(0, self.run_tmux(socket, "new-session", "-d", "-s", "probe").returncode)
        self.assertEqual(0, self.run_tmux(socket, "list-sessions").returncode)

        cleanup = self.run_runner("cleanup", "--state", state)
        self.assertEqual(0, cleanup.returncode, cleanup.stderr)
        self.assertFalse(os.path.exists(state))
        self.assertNotEqual(0, self.run_tmux(socket, "list-sessions").returncode)

    def test_run_cleans_up_after_a_failing_command(self):
        proc = self.run_runner("run", "--", "sh", "-c", "exit 3")
        self.assertEqual(3, proc.returncode)
        state = self.state_from(proc)
        self.assertFalse(os.path.exists(state))

    # -- the incident, replayed inside the sandbox --------------------------

    def test_populated_tmux_reload_and_cleanup_stay_in_the_sandbox(self):
        sentinel_sock = self.start_sentinel()
        env = clean_env(
            TMPDIR=self.tmp, TMUX=f"{sentinel_sock},4242,0", TMUX_PANE="%42"
        )
        script = (
            "tmux new-session -d -s inside; "
            f"tmux source-file {FIXTURE_CONF}; "
            "tmux show-options -g @sandbox-marker; "
            "tmux kill-server; "
            "echo done"
        )
        proc = self.run_runner("run", "--", "sh", "-c", script, env=env)
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertIn("sandboxed", proc.stdout, "the fixture config did not load")
        self.assertIn("done", proc.stdout)
        state = self.state_from(proc)
        self.assertFalse(os.path.exists(state), "the sandbox state was not cleaned up")
        self.assert_sentinel_untouched()

    def test_nested_commands_cannot_fall_back_to_live_or_default(self):
        sentinel_sock = self.start_sentinel()
        env = clean_env(
            TMPDIR=self.tmp, TMUX=f"{sentinel_sock},4242,0", TMUX_PANE="%42"
        )
        script = (
            'echo "TMUX=${TMUX-unset} PANE=${TMUX_PANE-unset}"; '
            '"$REAL_TMUX" list-sessions 2>&1; echo "list=$?"'
        )
        proc = self.run_runner("run", "--", "sh", "-c", script, env=env)
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertIn("TMUX=unset PANE=unset", proc.stdout)
        state = self.state_from(proc)
        self.assertIn(f"{state}/tmp/tmux-{os.getuid()}/default", proc.stdout)
        self.assertNotIn("/private/tmp/tmux-", proc.stdout)
        self.assertNotIn(",4242,0", proc.stdout)
        self.assert_sentinel_untouched()

    def test_shim_refuses_socket_overrides(self):
        foreign = os.path.join(self.tmp, "foreign.sock")
        script = (
            "tmux -L other list-sessions; echo L=$?; "
            f"tmux -S {foreign} list-sessions; echo S=$?; "
            f"tmux -S{foreign} ls; echo A=$?"
        )
        proc = self.run_runner("run", "--", "sh", "-c", script)
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertIn("refusing socket override", proc.stderr)
        for marker in ("L=87", "S=87", "A=87"):
            self.assertIn(marker, proc.stdout)
        self.assertFalse(os.path.exists(foreign))

    def test_shim_refuses_clustered_socket_overrides(self):
        # tmux clusters global flags (-2S SOCKET), so a selector is not always
        # the first letter of the option.  None of these may reach a server.
        foreign_dir = tempfile.mkdtemp(prefix="tmux-foreign.", dir=self.tmp)
        self.created.append(foreign_dir)
        foreign = os.path.join(foreign_dir, "sock")
        script = (
            f"tmux -2S {foreign} list-sessions; echo A=$?; "
            f"tmux -2S{foreign} list-sessions; echo B=$?; "
            "tmux -2L other list-sessions; echo C=$?; "
            f"tmux -2f /dev/null -S {foreign} ls; echo D=$?"
        )
        proc = self.run_runner("run", "--", "sh", "-c", script)
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertIn("refusing socket override", proc.stderr)
        for marker in ("A=87", "B=87", "C=87", "D=87"):
            self.assertIn(marker, proc.stdout)
        self.assertFalse(os.path.exists(foreign))

    def test_shim_refuses_clustered_query_against_a_foreign_private_server(self):
        sentinel_sock = self.start_sentinel()
        script = (
            f"tmux -2S {sentinel_sock} show-options -g @sentinel-keep; echo Q=$?; "
            f"tmux -S {sentinel_sock} -2S {sentinel_sock} show-options -g @sentinel-keep; "
            "echo R=$?"
        )
        proc = self.run_runner("run", "--", "sh", "-c", script)
        self.assertEqual(0, proc.returncode, proc.stderr)
        for marker in ("Q=87", "R=87"):
            self.assertIn(marker, proc.stdout)
        self.assertNotIn("@sentinel-keep", proc.stdout)
        self.assert_sentinel_untouched()

    def test_shim_routes_navigation_and_subcommand_socket_values(self):
        # `capture-pane -S -100` is a command flag, not a global selector: the
        # shim must not consume it as one, and navigation must keep working.
        script = (
            "tmux new-session -d -s nav; echo new=$?; "
            "tmux capture-pane -p -S -100 -t nav >/dev/null; echo cap=$?; "
            "tmux -2 list-windows -t nav >/dev/null; echo win=$?"
        )
        proc = self.run_runner("run", "--", "sh", "-c", script)
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertNotIn("refusing socket override", proc.stderr)
        for marker in ("new=0", "cap=0", "win=0"):
            self.assertIn(marker, proc.stdout)

    # -- refusal to clean up anything not owned -----------------------------

    def test_cleanup_refuses_outside_owned_resources(self):
        self.start_sentinel()
        fake = os.path.join(self.tmp, f"dotfiles-tmux-sandbox.{os.getpid():x}")
        os.makedirs(os.path.join(fake, "run"), mode=0o700)
        os.chmod(fake, 0o700)
        self.created.append(fake)

        for target in (self.sentinel, "/", self.tmp, fake):
            proc = self.run_runner("cleanup", "--state", target)
            self.assertNotEqual(0, proc.returncode, target)
            self.assertIn("refuse", proc.stderr, target)

        self.assertTrue(os.path.isdir(self.sentinel))
        self.assertTrue(os.path.isdir(fake))
        self.assert_sentinel_untouched()

    def test_run_refuses_an_unowned_state(self):
        self.start_sentinel()
        proc = self.run_runner("run", "--state", self.sentinel, "--", "true")
        self.assertNotEqual(0, proc.returncode)
        self.assertIn("refuse", proc.stderr)
        self.assert_sentinel_untouched()


if __name__ == "__main__":
    unittest.main()

"""Regression fixtures for scripts/tmux-sandbox.

Every tmux server here is private: a tmux-sandbox state or a sentinel with an
explicit -S socket under this test's temporary directory.  The fixture config
(no plugins, no network) is always loaded with -f, never ~/.tmux.conf.
"""

import os
import re
import shutil
import subprocess
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUNNER = os.path.join(REPO, "scripts", "tmux-sandbox")
FIXTURE_CONF = os.path.join(REPO, "scripts", "tests", "fixtures", "tmux-sandbox.conf")
TMUX = shutil.which("tmux")
TMUX_REAL = os.path.realpath(TMUX) if TMUX else None
STATE_RE = re.compile(r"^tmux-sandbox: state (.+)$", re.MULTILINE)


def clean_env(**extra):
    env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")}
    env.update(extra)
    return env


@unittest.skipUnless(TMUX, "tmux is required for the sandbox fixtures")
class SandboxTests(unittest.TestCase):
    def setUp(self):
        # States live under the real temporary directory, as in production,
        # because a tmux socket path has a hard length limit.
        self.tmp = os.path.realpath(tempfile.gettempdir())
        self.created, self.sentinel_sock, self.sentinel_options = [], None, None
        self.addCleanup(self.cleanup)

    def cleanup(self):
        if self.sentinel_sock and os.path.exists(self.sentinel_sock):
            self.run_tmux(self.sentinel_sock, "kill-server")
        for path in reversed(self.created):
            shutil.rmtree(path, ignore_errors=True)  # safety net for leaked states

    def run_tmux(self, socket, *args):
        cmd = [TMUX, "-S", socket, "-f", FIXTURE_CONF, *args]
        return subprocess.run(cmd, env=clean_env(HOME=self.tmp), capture_output=True, text=True)

    def run_runner(self, *args, env=None):
        return subprocess.run(
            [RUNNER, *args], env=clean_env() if env is None else env, capture_output=True, text=True
        )

    def start_sentinel(self):
        """Start an unrelated private server that the sandbox must never touch."""
        sentinel = os.path.realpath(tempfile.mkdtemp(prefix="tmux-sandbox-sentinel.", dir=self.tmp))
        self.created.append(sentinel)
        os.chmod(sentinel, 0o700)
        self.sentinel_sock = os.path.join(sentinel, "sock")
        proc = self.run_tmux(self.sentinel_sock, "new-session", "-d", "-s", "sentinel")
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.run_tmux(self.sentinel_sock, "set-option", "-g", "@sentinel-keep", "yes")
        self.sentinel_options = self.run_tmux(self.sentinel_sock, "show-options", "-g").stdout
        return self.sentinel_sock


    def assert_sentinel_untouched(self):
        listed = self.run_tmux(self.sentinel_sock, "list-sessions")
        self.assertEqual((listed.returncode, "sentinel" in listed.stdout), (0, True), listed.stderr)
        options = self.run_tmux(self.sentinel_sock, "show-options", "-g").stdout
        self.assertEqual(self.sentinel_options, options, "the sentinel options changed")

    def state_from(self, proc):
        match = STATE_RE.search(proc.stderr)
        self.assertIsNotNone(match, proc.stderr)
        self.created.append(match.group(1))
        return match.group(1)

    def test_a_run_is_private_and_cleans_up(self):
        sentinel = self.start_sentinel()
        proc = self.run_runner(
            "--",
            "sh",
            "-c",
            "set -eu\n"
            'test -z "${TMUX:-}" || { echo leaked >&2; exit 9; }\n'
            'test -z "${TMUX_PANE:-}" || { echo leaked >&2; exit 9; }\n'
            'tmux new-session -d -s solo\ntmux source-file "$1"\n'
            "tmux show-options -g @sandbox-marker\ntmux list-sessions\n",
            "sh",
            FIXTURE_CONF,
            env=clean_env(TMUX=sentinel + ",999,0", TMUX_PANE="%9"),
        )
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertIn("solo", proc.stdout)
        self.assertIn("sandboxed", proc.stdout)
        self.assertNotIn("sentinel", proc.stdout)
        state = self.state_from(proc)
        self.assertFalse(os.path.exists(os.path.join(state, "run", "tmux.sock")), "socket leaked")
        self.assertFalse(os.path.exists(state), "state leaked")
        self.assert_sentinel_untouched()

    def test_a_nested_tmux_without_the_shim_cannot_reach_the_default_socket(self):
        proc = self.run_runner(
            "--", "sh", "-c", 'printf "tmpdir=%s\\n" "$TMUX_TMPDIR"; "$1" list-sessions 2>&1 || true', "sh", TMUX_REAL
        )
        self.assertEqual(0, proc.returncode, proc.stderr)
        state = self.state_from(proc)
        self.assertIn("tmpdir=" + os.path.join(state, "tmp"), proc.stdout)
        self.assertIn(os.path.join(state, "tmp", "tmux-%d" % os.getuid(), "default"), proc.stdout)
        self.assertNotIn(os.path.join(self.tmp, "tmux-%d" % os.getuid(), "default"), proc.stdout)

    def test_the_strict_shim_refuses_every_leading_global_option(self):
        sentinel = self.start_sentinel()
        cases = (["-S", sentinel], ["-S" + sentinel], ["-2S", sentinel], ["-L", "default"], ["-Ldefault"], ["-f", FIXTURE_CONF])
        for overrides in cases:
            proc = self.run_runner("--", "sh", "-c", 'tmux "$@" kill-server; echo "rc=$?"', "sh", *overrides)
            self.assertEqual(0, proc.returncode, proc.stderr)
            self.assertIn("rc=87", proc.stdout, overrides)
            self.assertIn("refusing global option", proc.stderr, overrides)
            self.assert_sentinel_untouched()

    def test_subcommand_flags_and_socket_values_stay_legal(self):
        proc = self.run_runner(
            "--",
            "sh",
            "-c",
            "set -eu\ntmux new-session -d -s nav\ntmux display-message -p -F '#{socket_path}'\ntmux capture-pane -p -S -5 -t nav\n",
        )
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertIn(os.path.join(self.state_from(proc), "run", "tmux.sock"), proc.stdout)

    def test_no_mode_operates_on_a_caller_supplied_path(self):
        bad = ((), ("new",), ("cleanup", "--state", "/"), ("--state", "/tmp", "--", "echo", "hi"), ("run", "--", "echo", "hi"))
        for args in bad:
            proc = self.run_runner(*args)
            self.assertEqual(2, proc.returncode, args)
            self.assertIn("usage: tmux-sandbox -- CMD", proc.stderr, args)


if __name__ == "__main__":
    unittest.main()

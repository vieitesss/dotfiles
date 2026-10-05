#!/usr/bin/env python3
"""Tests for the shared tmux destructive-command guard (scripts/lib/tmux_guard.py).

Run from the repository root:

    python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v
"""

import json
import os
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO, "scripts", "lib"))

import tmux_guard  # noqa: E402


def make_owned_state(tmpdir, name="dotfiles-tmux-sandbox.test01"):
    """Build a sandbox state directory by hand, mirroring tmux-sandbox's layout.

    Created independently of tmux_guard's own writer so the ownership tests
    exercise the reader against real files, not a shared helper.
    """
    state = os.path.join(tmpdir, name)
    run_dir = os.path.join(state, "run")
    os.makedirs(run_dir, mode=0o700)
    os.chmod(state, 0o700)
    os.chmod(run_dir, 0o700)
    socket = os.path.join(run_dir, "tmux.sock")
    with open(os.path.join(state, "state.json"), "w", encoding="utf-8") as handle:
        json.dump({"version": 1, "socket": socket, "runner": "tmux-sandbox"}, handle)
    os.chmod(os.path.join(state, "state.json"), 0o600)
    return state, socket


class GuardDecisionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="tmux-guard-test.", dir="/tmp"))
        os.chmod(self.tmp, 0o700)
        self.addCleanup(self._cleanup_tmp)
        self.live = "/tmp/live-owner/default"

    def _cleanup_tmp(self):
        import shutil

        shutil.rmtree(self.tmp, ignore_errors=True)

    def evaluate(self, command, **kwargs):
        env = {"TMUX": f"{self.live},123,0"}
        env.update(kwargs.pop("env", {}))
        return tmux_guard.evaluate(
            command,
            cwd=kwargs.pop("cwd", "/work"),
            env=env,
            tmpdir=kwargs.pop("tmpdir", self.tmp),
            **kwargs,
        )

    # -- the guarded set ----------------------------------------------------

    def test_live_and_default_destructive_calls_ask(self):
        commands = [
            "tmux kill-server",
            "tmux kill-session",
            "tmux kill-session -t work",
            "tmux kill-server -f /dev/null",
            "tmux source-file ~/.tmux.conf",
            "tmux source ~/.tmux.conf",
            "tmux kill-client -t /dev/ttys001",
            "tmux kill-window -a",
            "tmux kill-window -at @1",
            "tmux killw -a",
            "tmux kill-pane -a",
            "tmux killp -a",
            "tmux detach-client -a",
            "tmux detach -P",
            "tmux kill-serv",
            "tmux kill-s",
            "tmux kill-session -C -t work",
        ]
        for command in commands:
            self.assertEqual("ask", self.evaluate(command).kind, command)

    def test_explicit_owned_socket_is_allowed(self):
        state, socket = make_owned_state(self.tmp)
        self.assertEqual("allow", self.evaluate(f"tmux -S {socket} kill-server").kind)
        self.assertEqual("allow", self.evaluate(f"tmux -S {socket} source-file /dev/null").kind)

    def test_relative_owned_socket_resolves_against_cwd(self):
        state, socket = make_owned_state(self.tmp)
        self.assertEqual(
            "allow",
            self.evaluate("tmux -S run/tmux.sock kill-server", cwd=state).kind,
        )

    def test_unrelated_private_socket_asks(self):
        other = os.path.join(self.tmp, "not-a-sandbox")
        os.makedirs(other, mode=0o700)
        socket = os.path.join(other, "tmux.sock")
        decision = self.evaluate(f"tmux -S {socket} kill-server")
        self.assertEqual("ask", decision.kind)
        self.assertIn("not an owned", decision.reason)

    def test_sandbox_looking_directory_without_marker_asks(self):
        # A directory named like a sandbox is not enough to prove ownership.
        fake = os.path.join(self.tmp, "dotfiles-tmux-sandbox.deadbeef")
        os.makedirs(os.path.join(fake, "run"), mode=0o700)
        os.chmod(fake, 0o700)
        socket = os.path.join(fake, "run", "tmux.sock")
        self.assertEqual("ask", self.evaluate(f"tmux -S {socket} kill-server").kind)

    def test_owned_socket_equal_to_live_still_asks(self):
        state, socket = make_owned_state(self.tmp)
        decision = self.evaluate(f"tmux -S {socket} kill-server", env={"TMUX": f"{socket},1,0"})
        self.assertEqual("ask", decision.kind)
        self.assertIn("live", decision.reason)

    def test_l_takes_precedence_and_asks(self):
        self.assertEqual("ask", self.evaluate("tmux -L other kill-server").kind)
        decision = self.evaluate("tmux -L other kill-server")
        self.assertIn("-L", decision.reason)

    # -- clustered and repeated global socket selectors ---------------------

    def test_clustered_socket_selector_after_owned_asks(self):
        # tmux accepts global options clustered (-2S socket) and a later -S/-L
        # changes the server the command runs on, so the first owned selector
        # must not authorize the call.
        state, owned = make_owned_state(self.tmp)
        sentinel_dir = os.path.join(self.tmp, "sentinel")
        os.makedirs(sentinel_dir, mode=0o700)
        os.chmod(sentinel_dir, 0o700)
        sentinel = os.path.join(sentinel_dir, "sock")
        commands = [
            f"tmux -S {owned} -2S {sentinel} kill-server",
            f"tmux -S {owned} -2S{sentinel} kill-server",
            f"tmux -S {owned} -2L other kill-server",
            f"tmux -S {owned} -2Lother kill-server",
            f"tmux -S {owned} -S {sentinel} kill-server",
            f"tmux -S {owned} -S {owned} kill-server",
            f"tmux -L other -S {owned} kill-server",
            f"tmux -S {owned} -2S {self.live} kill-server",
        ]
        for command in commands:
            decision = self.evaluate(command)
            self.assertEqual("ask", decision.kind, command)
            self.assertIn("more than one socket selector", decision.reason, command)

    def test_clustered_selector_without_an_owned_socket_asks(self):
        sentinel = os.path.join(self.tmp, "sentinel", "sock")
        for command in [f"tmux -2S {sentinel} kill-server", "tmux -2L other kill-server"]:
            self.assertEqual("ask", self.evaluate(command).kind, command)

    def test_clustered_global_flags_around_one_owned_selector_allow(self):
        state, owned = make_owned_state(self.tmp)
        commands = [
            f"tmux -2S {owned} kill-server",
            f"tmux -2S{owned} kill-server",
            f"tmux -2f /dev/null -S {owned} kill-server",
            f"tmux -S {owned} -2f /dev/null kill-server",
            f"tmux -2T 256 -S {owned} kill-server",
            f"tmux -S {owned} -2 kill-window -t @7",
        ]
        for command in commands:
            self.assertEqual("allow", self.evaluate(command).kind, command)

    def test_clustered_c_shell_command_is_judged(self):
        self.assertEqual("ask", self.evaluate("tmux -2c 'tmux kill-server'").kind)
        self.assertEqual("allow", self.evaluate("tmux -2c 'tmux ls'").kind)

    def test_subcommand_socket_like_flags_are_not_global_selectors(self):
        state, owned = make_owned_state(self.tmp)
        for command in [
            "tmux capture-pane -p -S -100",
            f"tmux -S {owned} capture-pane -p -S -100",
        ]:
            self.assertEqual("allow", self.evaluate(command).kind, command)

    # -- chains and wrappers ------------------------------------------------

    def test_chain_with_owned_first_still_asks(self):
        state, socket = make_owned_state(self.tmp)
        command = f"tmux -S {socket} list-sessions; tmux kill-server"
        self.assertEqual("ask", self.evaluate(command).kind)

    def test_chain_of_owned_operations_allowed(self):
        state, socket = make_owned_state(self.tmp)
        command = f"tmux -S {socket} list-sessions && tmux -S {socket} kill-server"
        self.assertEqual("allow", self.evaluate(command).kind)

    def test_wrapped_commands_request_approval(self):
        commands = [
            "command tmux kill-server",
            "sudo tmux kill-server",
            "env FOO=bar tmux kill-server",
            "sh -c 'tmux kill-server'",
            "bash -lc \"tmux kill-server\"",
            "eval 'tmux kill-server'",
            "$(tmux kill-server)",
            "echo $(tmux kill-server)",
            "xargs tmux kill-server",
            "timeout 5 tmux kill-server",
            "some-wrapper tmux kill-server",
            "tmux run-shell 'tmux kill-server'",
            "tmux if-shell 'true' 'kill-server'",
            "tmux bind-key k kill-server",
            "tmux confirm-before -p 'sure?' kill-server",
            "tmux kill-window -t @1 \\; kill-server",
        ]
        for command in commands:
            self.assertEqual("ask", self.evaluate(command).kind, command)

    def test_wrapped_owned_commands_allowed(self):
        state, socket = make_owned_state(self.tmp)
        commands = [
            f"sudo tmux -S {socket} kill-server",
            f"bash -lc 'tmux -S {socket} kill-server'",
            f"tmux -S {socket} run-shell 'echo hi'",
            f"tmux -S {socket} if-shell 'true' 'list-sessions'",
        ]
        for command in commands:
            self.assertEqual("allow", self.evaluate(command).kind, command)

    def test_process_killing_requests_approval(self):
        for command in ["pkill -f tmux", "pkill tmux", "killall tmux", "kill $(pgrep tmux)"]:
            self.assertEqual("ask", self.evaluate(command).kind, command)
        self.assertEqual("allow", self.evaluate("pgrep tmux").kind)

    def test_shell_alias_definitions_request_approval(self):
        self.assertEqual(
            "ask", self.evaluate("alias kk='tmux kill-server'; kk").kind
        )

    def test_quoted_data_is_not_an_operation(self):
        commands = [
            'echo "tmux kill-server"',
            "grep -rn 'tmux kill-server' docs/",
            'printf "%s" "tmux kill-server"',
        ]
        for command in commands:
            self.assertEqual("allow", self.evaluate(command).kind, command)

    def test_unparsable_destructive_command_asks(self):
        self.assertEqual("ask", self.evaluate("tmux kill-server 'unbalanced").kind)

    def test_unparsable_harmless_command_allowed(self):
        self.assertEqual("allow", self.evaluate("tmux ls 'unbalanced").kind)

    def test_dangling_socket_flag_does_not_crash(self):
        for command in ["tmux -S", "tmux -L", "tmux -S '' ls"]:
            self.assertIn(self.evaluate(command).kind, ("allow", "ask"), command)

    def test_unrelated_commands_allowed(self):
        for command in ["ls -la", "git status", "echo hello", "kill -9 1234", "grep kill-server docs/"]:
            self.assertEqual("allow", self.evaluate(command).kind, command)

    def test_substitution_used_as_a_command_word_asks(self):
        for command in ["$(which tmux) kill-server", "`which tmux` kill-server"]:
            self.assertEqual("ask", self.evaluate(command).kind, command)

    def test_redirects_and_conditionals_do_not_hide_operations(self):
        commands = [
            "tmux kill-server > /dev/null 2>&1",
            "if true; then tmux kill-server; fi",
            "cd /tmp && tmux kill-server",
            "noop || tmux kill-session -t work",
        ]
        for command in commands:
            self.assertEqual("ask", self.evaluate(command).kind, command)

    def test_attached_socket_flag_is_understood(self):
        state, socket = make_owned_state(self.tmp)
        self.assertEqual("allow", self.evaluate(f"tmux -S{socket} kill-server").kind)
        self.assertEqual("ask", self.evaluate("tmux -S/tmp/elsewhere/sock kill-server").kind)

    def test_tmux_wrapped_in_env_assignment_asks(self):
        self.assertEqual("ask", self.evaluate("TMUX=/tmp/x tmux kill-server").kind)
        self.assertEqual(
            "ask", self.evaluate("TMUX_TMPDIR=/tmp/x tmux kill-server").kind
        )

    def test_on_server_command_lists_are_guarded(self):
        state, socket = make_owned_state(self.tmp)
        self.assertEqual(
            "allow",
            self.evaluate(f"tmux -S {socket} new-session \\; list-sessions").kind,
        )
        self.assertEqual(
            "ask",
            self.evaluate(f"tmux -S {socket} new-session \\; kill-server; tmux kill-server").kind,
        )

    def test_exported_variable_with_destructive_body_asks(self):
        self.assertEqual(
            "ask", self.evaluate("export X='tmux kill-server'; $X").kind
        )

    def test_nested_shell_side_effects_are_never_scoped_by_the_outer_socket(self):
        # An owned outer socket must not authorize a nested shell command that
        # names a foreign or live target; tmux command lists still may, because
        # they run against the outer server itself.
        state, owned = make_owned_state(self.tmp)
        sentinel_dir = os.path.join(self.tmp, "sentinel")
        os.makedirs(sentinel_dir, mode=0o700)
        os.chmod(sentinel_dir, 0o700)
        sentinel = os.path.join(sentinel_dir, "sock")

        ask = [
            f"tmux -S {owned} run-shell 'tmux kill-server'",
            f"tmux -S {owned} run-shell 'tmux -S {sentinel} kill-server'",
            f"tmux -S {owned} run-shell 'tmux -S {self.live} kill-server'",
            f"tmux -S {owned} if-shell 'tmux -S {sentinel} kill-server' 'list-sessions'",
            f"tmux -S {owned} detach-client -E 'tmux kill-server'",
            "tmux run-shell 'echo hi' \\; kill-server",
            "tmux bind-key k kill-server",
            "tmux if-shell 'true' 'kill-server'",
        ]
        for command in ask:
            self.assertEqual("ask", self.evaluate(command).kind, command)

        allow = [
            f"tmux -S {owned} run-shell 'echo hi'",
            f"tmux -S {owned} run-shell 'tmux -S {owned} kill-server'",
            f"tmux -S {owned} if-shell 'true' 'kill-server'",
            f"tmux -S {owned} if-shell 'true' 'list-sessions; kill-server'",
            f"tmux -S {owned} bind-key k kill-server",
            f"tmux -S {owned} detach-client -a",
            f"tmux -S {owned} run-shell 'echo hi' \\; kill-server",
        ]
        for command in allow:
            self.assertEqual("allow", self.evaluate(command).kind, command)

    def test_tmux_abbreviations_and_command_lists(self):
        for command in [
            "tmux kill-serv",
            "tmux kill-ses -t work",
            "tmux run-sh 'tmux kill-server'",
            "tmux if-sh 'true' 'kill-server'",
            "tmux bind k kill-server",
            "tmux kill-serv 'unbalanced",
        ]:
            self.assertEqual("ask", self.evaluate(command).kind, command)
        self.assertEqual("allow", self.evaluate("tmux bind-key k new-window").kind)
        self.assertEqual("allow", self.evaluate("tmux bind-key j select-pane -D").kind)

    def test_unqualified_kill_server_asks(self):
        decision = self.evaluate("tmux kill-server")
        self.assertEqual("ask", decision.kind)
        self.assertIn("live", decision.reason)

    def test_navigation_and_targeted_close_allowed(self):
        commands = [
            "tmux ls",
            "tmux display-message -p '#{session_id}'",
            "tmux split-window -h -c '#{pane_current_path}'",
            "tmux new-window -d -t work: -n build",
            "tmux send-keys -t %3 Enter",
            "tmux capture-pane -p -t %3",
            "tmux load-buffer -b x -",
            "tmux paste-buffer -p -d -b x -t %3",
            "tmux set-option -w remain-on-exit on",
            "tmux kill-window -t @7",
            "tmux kill-pane -t %9",
            "tmux killw -t @7",
            "tmux killp -t %9",
            "tmux show-options -g",
        ]
        for command in commands:
            self.assertEqual("allow", self.evaluate(command).kind, command)


class GuardCliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="tmux-guard-cli.", dir="/tmp"))
        self.addCleanup(self._cleanup)
        self.guard = os.path.join(REPO, "scripts", "tmux-guard")
        self.env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_TMPDIR")}
        self.env["TMUX_TMPDIR"] = self.tmp + "/no-such-tmux"

    def _cleanup(self):
        import shutil

        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_guard(self, *args):
        import subprocess

        return subprocess.run(
            [sys.executable, self.guard, *args],
            capture_output=True,
            text=True,
            check=False,
            env=self.env,
        )

    def test_destructive_command_prints_ask(self):
        proc = self.run_guard("--", "tmux kill-server")
        self.assertEqual(0, proc.returncode)
        self.assertTrue(proc.stdout.startswith("ask\t"), proc.stdout)
        self.assertEqual(1, len(proc.stdout.splitlines()))

    def test_harmless_command_prints_allow(self):
        proc = self.run_guard("--", "tmux ls")
        self.assertEqual(0, proc.returncode)
        self.assertEqual("allow\n", proc.stdout)

    def test_owned_socket_prints_allow(self):
        state, socket = make_owned_state(self.tmp)
        self.env["TMPDIR"] = self.tmp
        proc = self.run_guard("--", f"tmux -S {socket} kill-server")
        self.assertEqual(0, proc.returncode)
        self.assertEqual("allow\n", proc.stdout, proc.stderr)

    def test_missing_command_exits_two(self):
        proc = self.run_guard("--")
        self.assertEqual(2, proc.returncode)

    def test_injected_live_socket_is_never_owned(self):
        state, socket = make_owned_state(self.tmp)
        proc = self.run_guard(
            "--live-socket",
            socket,
            "--",
            f"tmux -S {socket} kill-server",
        )
        self.assertEqual("ask\t", proc.stdout[:4])


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Test-only runner: prepare one Stage offline and return its launch spec.

`unittest discover` imports this module but finds no tests in it; the test
modules share this one runner instead of repeating the Jev stub and the
stdout/stderr/argv capture shape. Each caller keeps its own fixture setup,
argv, and assertions.
"""

import contextlib
import io
import json
from unittest import mock

import subagent


def prepare_spec(argv):
    """Run subagent.main() with Jev stubbed; return the parsed launch spec.

    argv is the exact command line the scenario wants. Raises AssertionError
    when main() does not report success, so a failure names the runner.
    """
    answers = {"effort": {"choice": "medium"}, "model": {"choice": "builder"}}
    stdout = io.StringIO()
    with mock.patch.object(subagent, "jev", return_value=answers):
        with contextlib.redirect_stdout(stdout):
            with contextlib.redirect_stderr(io.StringIO()):
                with mock.patch("sys.argv", argv):
                    code = subagent.main()
    if code != 0:
        raise AssertionError(f"subagent.main() returned {code}")
    return json.loads(stdout.getvalue())

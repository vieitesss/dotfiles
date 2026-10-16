#!/usr/bin/env python3
"""Regression tests for ledger.py; each runs against a temp file."""

import contextlib
import io
import os
import tempfile
import unittest

import ledger

LEDGER = """# Ledger

| Item | Stage | Status | Report |
| ---- | ----- | ------ | ------ |
| login | build | running | login-build.md |
| twice | build | done | a.md |
| twice | build | done | a.md |

## Decisions
- login: keep the cookie.
"""


class LedgerTest(unittest.TestCase):
    def setUp(self):
        fd, self.path = tempfile.mkstemp(suffix=".md")
        with os.fdopen(fd, "w") as handle:
            handle.write(LEDGER)
        self.addCleanup(os.remove, self.path)

    def run_ledger(self, *argv):
        with contextlib.redirect_stderr(io.StringIO()):
            ledger.main(["--file", self.path, *argv])
        with open(self.path) as handle:
            return handle.read()

    def test_set_changes_one_cell_and_nothing_else(self):
        text = self.run_ledger("set", "login", "status", "accepted | merged")
        self.assertIn("| login | build | accepted \\| merged | login-build.md |", text)
        self.assertEqual(text.replace(
            "| login | build | accepted \\| merged | login-build.md |",
            "| login | build | running | login-build.md |"), LEDGER)

    def test_add_appends_after_the_last_row(self):
        text = self.run_ledger("add", "new", "Stage=write", "status=queued")
        self.assertIn("| twice | build | done | a.md |\n| new | write | queued |  |\n\n## Decisions", text)

    def test_ambiguous_rows_unknown_columns_and_duplicates_are_refused(self):
        for argv in (("set", "twice", "status", "x"), ("set", "login", "bogus", "x"),
                     ("set", "ghost", "status", "x"), ("add", "login")):
            with self.subTest(argv=argv), self.assertRaises(SystemExit):
                self.run_ledger(*argv)


if __name__ == "__main__":
    unittest.main()

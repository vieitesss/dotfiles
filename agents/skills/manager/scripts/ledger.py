#!/usr/bin/env python3
"""Edit the Work Item table in the main checkout's .agents/ledger.md.

Usage:
    ledger.py set ITEM COLUMN VALUE        change one cell of ITEM's row
    ledger.py add ITEM [COLUMN=VALUE ...]  append a row for a new Work Item

COLUMN is a header of the table, matched without case ("status", "Stage").
--file PATH edits another ledger. Prose sections stay hand-edited.
"""

import argparse
import os
import subprocess
import sys


def default_ledger():
    """.agents/ledger.md in the main checkout, even from a worktree."""
    common = subprocess.run(
        ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return os.path.join(os.path.dirname(common), ".agents", "ledger.md")


def cells(line):
    """A table row's cells, keeping escaped pipes inside their cell."""
    inner = line.strip()[1:-1].replace("\\|", "\0")
    return [cell.strip().replace("\0", "\\|") for cell in inner.split("|")]


def row(values):
    return "| " + " | ".join(values) + " |"


def find_table(lines):
    """(header index, column names) of the first table with an Item column."""
    for i, line in enumerate(lines):
        if line.startswith("|") and i + 1 < len(lines) and lines[i + 1].startswith("|"):
            names = cells(line)
            if names and names[0].lower() == "item":
                return i, names
    sys.exit("no table with an Item column in the ledger")


def column(names, wanted):
    for i, name in enumerate(names):
        if name.lower() == wanted.lower():
            return i
    sys.exit(f"no column {wanted!r}; columns: {', '.join(names)}")


def escape(value):
    return value.replace("|", "\\|").replace("\n", " ")


def set_cell(lines, item, col, value):
    header, names = find_table(lines)
    index = column(names, col)
    matches = []
    for i in range(header + 2, len(lines)):
        if not lines[i].startswith("|"):
            break
        if cells(lines[i])[0] == item:
            matches.append(i)
    if not matches:
        sys.exit(f"no row for {item!r}")
    if len(matches) > 1:
        sys.exit(f"{len(matches)} rows for {item!r} (lines "
                 f"{', '.join(str(i + 1) for i in matches)}); merge them first")
    values = cells(lines[matches[0]])
    values += [""] * (len(names) - len(values))
    values[index] = escape(value)
    lines[matches[0]] = row(values)


def add_row(lines, item, pairs):
    header, names = find_table(lines)
    values = [""] * len(names)
    values[0] = escape(item)
    for pair in pairs:
        col, sep, value = pair.partition("=")
        if not sep:
            sys.exit(f"{pair!r} is not COLUMN=VALUE")
        values[column(names, col)] = escape(value)
    end = header + 2
    while end < len(lines) and lines[end].startswith("|"):
        if cells(lines[end])[0] == item:
            sys.exit(f"{item!r} already has a row; use set")
        end += 1
    lines.insert(end, row(values))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--file")
    sub = parser.add_subparsers(dest="command", required=True)
    setter = sub.add_parser("set")
    setter.add_argument("item")
    setter.add_argument("column")
    setter.add_argument("value")
    adder = sub.add_parser("add")
    adder.add_argument("item")
    adder.add_argument("pairs", nargs="*", metavar="COLUMN=VALUE")
    args = parser.parse_args(argv)

    path = args.file or default_ledger()
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")
    if args.command == "set":
        set_cell(lines, args.item, args.column, args.value)
    else:
        add_row(lines, args.item, args.pairs)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())

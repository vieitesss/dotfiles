#!/usr/bin/env python3
# Usage: commit-entries.py preview <entries-file>
#        commit-entries.py commit <entries-file> <preview-token>
# Rows: START|END|PROJECT|DESCRIPTION (local YYYY-MM-DD HH:MM; empty project uses default).
import hashlib
import json
import os
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path
from subprocess import CalledProcessError, check_output

DEFAULT_PROJECT = "Firestarter: a CI/CD service"
TZ = "Europe/Madrid"
FMT = "%Y-%m-%d %H:%M"
os.environ["TZ"] = TZ


def cli(*args):
    return check_output(["clockify-cli", "-i=0", "--allow-name-for-id", *args], text=True)


def hours(minutes):
    return f"{minutes // 60}:{minutes % 60:02d}"


def duration(start, end):
    return int((datetime.strptime(end, FMT) - datetime.strptime(start, FMT)).total_seconds() // 60)


def entry_key(start, end, project, desc):
    return tuple(t.replace(" ", "T") + ":00" for t in (start, end)) + (project, desc)


def cell(value):
    return value.replace("|", "\\|")


def main():
    args = sys.argv[1:]
    if not ((len(args) == 2 and args[0] == "preview") or
            (len(args) == 3 and args[0] == "commit")):
        raise ValueError("Usage: commit-entries.py preview FILE | commit-entries.py commit FILE TOKEN")
    mode, file = args[:2]
    totals = Counter()
    rows = []
    for number, line in enumerate(Path(file).read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        start, end, project, desc = line.split("|", 3)
        a, b = [datetime.strptime(t, FMT) for t in (start, end)]
        minutes = (b - a).total_seconds() // 60
        if (a.strftime(FMT) != start or b.strftime(FMT) != end or a.date() != b.date()
                or minutes < 30 or not desc.strip()):
            raise ValueError(f"Invalid entry on line {number}: use one date, >=30 minutes and a description")
        rows.append((start, end, project.strip() or DEFAULT_PROJECT, desc))
        totals[start[:10]] += int(minutes)
    rows.sort()
    if not rows or any(a[1] > b[0] for a, b in zip(rows, rows[1:])):
        raise ValueError("The batch is empty or contains overlapping entries")

    projects = json.loads(cli("project", "list", "--not-archived", "--json")) or []
    lookup = {}
    for selector in {row[2] for row in rows}:
        matches = [p for p in projects if selector in (p["id"], p["name"])]
        if len(matches) != 1:
            raise ValueError(f"Expected one active project for {selector!r}; found {len(matches)}")
        lookup[selector] = matches[0]
    resolved = [(s, e, p["id"], p["name"], p["workspaceId"], d)
                for s, e, selector, d in rows for p in [lookup[selector]]]
    workspaces = {row[4] for row in resolved}
    if len(workspaces) != 1 or not next(iter(workspaces)):
        raise ValueError("All projects must belong to one known workspace")
    workspace = workspaces.pop()
    token = hashlib.sha256(json.dumps(resolved).encode()).hexdigest()
    summary = f"{len(rows)} entries | Total: {hours(sum(totals.values()))} h"

    if mode == "preview":
        print("| Date | Project | Description | Start | End | Duration |")
        print("|---|---|---|---|---|---:|")
        for start, end, _, name, _, desc in resolved:
            minutes = duration(start, end)
            print(f"| {start[:10]} | {cell(name)} | {cell(desc)} | {start[11:]} | {end[11:]} | {hours(minutes)} |")
        print("\n" + " · ".join(f"{day}: {hours(m)}" for day, m in sorted(totals.items())))
        print(f"{summary}\nPreview token: {token}")
        return 0

    if args[2] != token:
        raise ValueError("The batch differs from the preview; generate and confirm a new preview")

    def recorded():
        data = json.loads(cli("--workspace", workspace, "report", rows[0][0][:10],
                              rows[-1][1][:10], "--tz", TZ, "--json"))
        return Counter((t["start"][:19], t["end"][:19], row["projectId"], row["description"])
                       for row in data or [] if (t := row["timeInterval"]).get("end") and row["billable"])

    before = recorded()
    expected = {entry_key(start, end, project, desc) for start, end, project, _, _, desc in resolved}
    if any(before[key] > 1 for key in expected):
        raise ValueError("Duplicate Clockify entries match this batch; resolve them before continuing")

    for start, end, project, _, _, desc in resolved:
        key = entry_key(start, end, project, desc)
        if before[key]:
            print(f"EXISTS: {start} - {end} | {desc}")
            continue
        try:
            cli("--workspace", workspace, "manual", "-b", "-p", project, "-d", desc, "-s", start, "-e", end)
        except CalledProcessError:
            print(f"FAILED: {start} - {end} | {desc}", file=sys.stderr)
        else:
            print(f"OK: {start} - {end} | {desc}")

    after = recorded()
    verified = sum(after[key] == 1 for key in expected)
    print(f"SUMMARY: {verified}/{len(rows)} verified | {summary}")
    return 0 if verified == len(rows) else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, CalledProcessError) as error:
        sys.exit(str(error))

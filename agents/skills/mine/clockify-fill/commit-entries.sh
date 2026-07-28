#!/usr/bin/env bash
# Commit a table of Clockify time entries built by the clockify-fill skill.
#
# Usage: commit-entries.sh <entries-file>
#
# entries-file format, one entry per line, pipe-separated:
#   START|END|PROJECT|DESCRIPTION
# where START/END are "YYYY-MM-DD HH:MM". Blank lines and lines starting
# with # are ignored.
set -euo pipefail

file="${1:?usage: commit-entries.sh <entries-file>}"

ok=0
failed=0

while IFS='|' read -r start end project description; do
  [[ -z "$start" || "$start" == \#* ]] && continue
  out=$(mktemp)
  err=$(mktemp)
  if clockify-cli manual --allow-name-for-id -i=0 -b \
      -p "$project" -d "$description" -s "$start" -e "$end" >"$out" 2>"$err"; then
    echo "OK: $start - $end | $project | $description"
    ok=$((ok + 1))
  else
    echo "FAILED: $start - $end | $project | $description"
    cat "$err" >&2
    failed=$((failed + 1))
  fi
  rm -f "$out" "$err"
done <"$file"

echo "SUMMARY: $ok succeeded, $failed failed"
[[ "$failed" -eq 0 ]]

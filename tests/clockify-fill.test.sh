#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/agents/skills/clockify-fill/commit-entries.py"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export PATH="$tmp:$PATH" CLOCKIFY_TEST_STATE="$tmp/entries"

cat > "$tmp/clockify-cli" <<'PY'
#!/usr/bin/env python3
import json
import sys
from pathlib import Path
from os import environ

args = sys.argv[1:]
assert args[:2] == ["-i=0", "--allow-name-for-id"]
args = args[2:]
state = Path(environ["CLOCKIFY_TEST_STATE"])
rows = json.loads(state.read_text()) if state.exists() else []
if args[:2] == ["project", "list"]:
    print(json.dumps([{"id": "project-id", "name": "Firestarter: a CI/CD service", "workspaceId": "workspace-id"},
                      {"id": "other-id", "name": "Other", "workspaceId": "workspace-id"}]))
else:
    assert args[:2] == ["--workspace", "workspace-id"]
    if args[2] == "report":
        print(json.dumps(rows))
    else:
        assert args[2:4] == ["manual", "-b"] and environ["TZ"] == "Europe/Madrid"
        flags = dict(zip(args[4::2], args[5::2]))
        assert flags["-p"] in {"project-id", "other-id"}
        rows.append(dict(projectId=flags["-p"], description=flags["-d"], billable=True,
                         timeInterval={key: flags[flag].replace(" ", "T") + ":00+01:00"
                                       for key, flag in [("start", "-s"), ("end", "-e")]}))
        state.write_text(json.dumps(rows))
PY
chmod +x "$tmp/clockify-cli"

batch="$tmp/batch"
cat > "$batch" <<'EOF'
2026-11-09 08:00|2026-11-09 14:20||Morning
2026-11-09 15:20|2026-11-09 17:10|Other|Afternoon
EOF
preview=$("$script" preview "$batch")
grep -Fq '2 entries | Total: 8:10 h' <<< "$preview"
grep -Fq '| Firestarter: a CI/CD service | Morning |' <<< "$preview"
grep -Fq '| Other | Afternoon |' <<< "$preview"
token=${preview##*Preview token: }
cp "$batch" "$tmp/original"
printf '%s\n' '2026-11-10 08:00|2026-11-10 09:00||Changed batch' >> "$batch"
if "$script" commit "$batch" "$token"; then exit 1; fi
printf '%s\n' '2026-11-09 08:30|2026-11-09 09:00||Overlap' >> "$batch"
if "$script" preview "$batch"; then exit 1; fi
[[ ! -e "$CLOCKIFY_TEST_STATE" ]]
cp "$tmp/original" "$batch"
result=$("$script" commit "$batch" "$token")
grep -Fq 'SUMMARY: 2/2 verified' <<< "$result"
result=$("$script" commit "$batch" "$token")
[[ $(grep -c '^EXISTS:' <<< "$result") == 2 ]]
grep -Fq 'SUMMARY: 2/2 verified' <<< "$result"

#!/bin/sh
set -eu

skill_dir=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
helper=$skill_dir/scripts/pi-subagent.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pi-subagent-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/bin" "$tmp/work"

cat > "$tmp/bin/pi" <<'FAKE_PI'
#!/bin/sh
set -eu
session=
model=
effort=
prompt=
print=false
no_extensions=false
no_skills=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        -p) print=true; shift ;;
        --session) session=$2; shift 2 ;;
        --model) model=$2; shift 2 ;;
        --thinking) effort=$2; shift 2 ;;
        --no-extensions) no_extensions=true; shift ;;
        --no-skills) no_skills=true; shift ;;
        --skill) shift 2 ;;
        @*) prompt=${1#@}; shift ;;
        *) shift ;;
    esac
done
[ "$print" = true ] && [ "$no_extensions" = true ] && [ "$no_skills" = true ] || exit 9
grep -q 'Do not spawn further agents' "$prompt" || exit 9
printf '%s|%s|%s\n' "$model" "$effort" "$prompt" >> "$session"
if grep -q 'FAIL' "$prompt"; then
    printf 'partial response\n'
    printf 'fake pi failure\n' >&2
    exit 7
fi
printf 'fake response\n'
if [ -n "${FAKE_PI_GATE:-}" ]; then
    while [ ! -e "$FAKE_PI_GATE" ]; do sleep 1; done
fi
FAKE_PI
chmod +x "$tmp/bin/pi"
git init -q "$tmp/work"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

value() {
    key=$1
    printf '%s\n' "$2" | awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

cd "$tmp/work"
printf 'Do the task.\n' > task.md
output=$(PATH="$tmp/bin:$PATH" FAKE_PI_GATE="$tmp/gate" "$helper" start --async task.md)
id=$(value id "$output")
result=$(value result "$output")
exit_file=$(value exit_code "$output")
[ -n "$id" ] || fail 'start did not return an id'
[ -d ".pi-subagent-runs/$id" ] || fail 'task-specific session directory missing'
exclude=$(git rev-parse --git-path info/exclude)
grep -Fqx '/.pi-subagent-runs/' "$exclude" || fail 'local Git exclude was not updated'
[ ! -e .gitignore ] || fail 'start created a tracked .gitignore'
[ ! -e "$result" ] || fail 'async result was published before Pi exited'
[ ! -e "$exit_file" ] || fail 'exit marker appeared before Pi exited'
: > "$tmp/gate"
PATH="$tmp/bin:$PATH" "$helper" wait "$id" >/dev/null
[ "$(cat "$exit_file")" = 0 ] || fail 'async turn did not succeed'
[ "$(cat "$result")" = 'fake response' ] || fail 'result artifact did not contain final response'

session=$(value session "$output")
printf 'Continue the task.\n' > follow-up.md
follow_output=$(PATH="$tmp/bin:$PATH" "$helper" follow-up "$id" follow-up.md)
[ "$(value session "$follow_output")" = "$session" ] || fail 'follow-up changed the session path'
[ "$(wc -l < "$session" | tr -d ' ')" = 2 ] || fail 'follow-up did not reuse the session'
[ "$(cut -d '|' -f 1,2 "$session" | uniq | wc -l | tr -d ' ')" = 1 ] || fail 'follow-up did not reuse the model profile'
[ "$(cut -d '|' -f 1,2 "$session" | head -n 1)" = 'openai-codex/gpt-5.6-luna|max' ] || fail 'default model profile was not used'

printf 'Continue with a replacement profile.\n' > replacement.md
PATH="$tmp/bin:$PATH" "$helper" follow-up "$id" --model custom/test --effort low replacement.md >/dev/null
[ "$(tail -n 1 "$session" | cut -d '|' -f 1,2)" = 'custom/test|low' ] || fail 'complete replacement model profile was not persisted'
turns_before=$(find ".pi-subagent-runs/$id" -name 'turn-*.prompt.md' | wc -l | tr -d ' ')
if PATH="$tmp/bin:$PATH" "$helper" follow-up "$id" --model incomplete replacement.md >/dev/null 2>&1; then
    fail 'partial model profile override succeeded'
fi
turns_after=$(find ".pi-subagent-runs/$id" -name 'turn-*.prompt.md' | wc -l | tr -d ' ')
[ "$turns_before" = "$turns_after" ] || fail 'partial model profile override created a turn'
status_output=$(PATH="$tmp/bin:$PATH" "$helper" status "$id")
printf '%s\n' "$status_output" | grep -q 'status=succeeded' || fail 'status did not report success'
list_output=$(PATH="$tmp/bin:$PATH" "$helper" list)
printf '%s\n' "$list_output" | grep -q "id=$id .*status=succeeded" || fail 'list did not include the completed session'

printf 'Block until stopped.\n' > stop.md
stop_output=$(PATH="$tmp/bin:$PATH" FAKE_PI_GATE="$tmp/stop-gate" "$helper" start --async stop.md)
stop_id=$(value id "$stop_output")
stop_result=$(value result "$stop_output")
PATH="$tmp/bin:$PATH" "$helper" status "$stop_id" | grep -q 'status=running' || fail 'status did not report running turn'
if PATH="$tmp/bin:$PATH" "$helper" follow-up "$stop_id" stop.md >/dev/null 2>&1; then
    fail 'concurrent follow-up against one session succeeded'
fi
PATH="$tmp/bin:$PATH" "$helper" stop "$stop_id" >/dev/null
set +e
PATH="$tmp/bin:$PATH" "$helper" wait "$stop_id" >/dev/null
stop_status=$?
set -e
[ "$stop_status" = 143 ] || fail "stopped child returned $stop_status instead of 143"
[ ! -e "$stop_result" ] || fail 'stopped child published a result artifact'

printf 'FAIL this task.\n' > fail.md
set +e
failed_output=$(PATH="$tmp/bin:$PATH" "$helper" start fail.md)
failed_status=$?
set -e
[ "$failed_status" = 7 ] || fail "failed child returned $failed_status instead of 7"
failed_result=$(value result "$failed_output")
failed_stderr=$(value stderr "$failed_output")
failed_exit=$(value exit_code "$failed_output")
failed_partial=${failed_result%.md}.partial.md
[ ! -e "$failed_result" ] || fail 'failed child published a result artifact'
[ "$(cat "$failed_partial")" = 'partial response' ] || fail 'failed child partial output was not preserved'
[ "$(cat "$failed_stderr")" = 'fake pi failure' ] || fail 'failed child stderr was not preserved'
[ "$(cat "$failed_exit")" = 7 ] || fail 'failed child exit code was not preserved'

printf 'ok\n'

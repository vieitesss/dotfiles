#!/bin/sh
set -eu

skill_dir=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
helper=$skill_dir/scripts/pi-subagent.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pi-subagent-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/bin" "$tmp/bin-notmux" "$tmp/work" "$tmp/tmux-state"

: > "$tmp/intercom.ts"

cat > "$tmp/bin/pi" <<'FAKE_PI'
#!/bin/sh
set -eu
session=
model=
effort=
prompt=
name=
print=false
no_extensions=false
no_skills=false
extensions=
exclude_tools=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -p) print=true; shift ;;
        -n|--name) name=$2; shift 2 ;;
        --session) session=$2; shift 2 ;;
        --model) model=$2; shift 2 ;;
        --thinking) effort=$2; shift 2 ;;
        -e|--extension) extensions="${extensions:+$extensions }$2"; shift 2 ;;
        --exclude-tools) exclude_tools=$2; shift 2 ;;
        --no-extensions) no_extensions=true; shift ;;
        --no-skills) no_skills=true; shift ;;
        --skill) shift 2 ;;
        @*) prompt=${1#@}; shift ;;
        *) shift ;;
    esac
done
[ "$no_extensions" = true ] && [ "$no_skills" = true ] || exit 9
[ -n "$name" ] || exit 9
case " $extensions " in
    *" ${FAKE_INTERCOM_EXT:-} "*) ;;
    *) exit 9 ;;
esac
if [ "$print" = true ]; then
    # Headless mode: watch-exit extension must NOT be loaded.
    case " $extensions " in
        *" ${FAKE_WATCH_EXT:-} "*) exit 9 ;;
    esac
else
    # Pane mode: the child is the real pi TUI; the watch-exit extension must be loaded.
    [ -n "${FAKE_WATCH_EXT:-}" ] || exit 9
    case " $extensions " in
        *" ${FAKE_WATCH_EXT} "*) ;;
        *) exit 9 ;;
    esac
fi
grep -q 'Do not spawn further agents' "$prompt" || exit 9
grep -q 'TASK COMPLETE:' "$prompt" || exit 9
if grep -q 'FAIL' "$prompt"; then
    stop_reason=error
    fake_text='partial response'
else
    stop_reason=end_turn
    fake_text='fake response'
fi
# Critic answer depends on the plan state at launch time; compute it before
# the session message is written below.
critic_plan=$(sed -n 's|^Plan: \(.*\)$|\1|p' "$prompt" | head -n 1)
if grep -q 'CRITIC stage' "$prompt" && [ -n "$critic_plan" ] && [ -f "$critic_plan" ]; then
    if grep -q '^- \[ \]' "$critic_plan"; then
        fake_text='FIX: 1. unchecked nodes remain in the plan'
    else
        fake_text='PASS - all nodes verified against their acceptance criteria'
    fi
fi
{
    printf '{"type":"session","version":3}\n'
    printf '{"type":"message","id":"u1","message":{"role":"user","content":[{"type":"text","text":"user"}]}}\n'
    printf '{"type":"message","id":"a1","message":{"role":"assistant","content":[{"type":"text","text":"%s"}],"stopReason":"%s"}}\n' "$fake_text" "$stop_reason"
} >> "$session"
printf '%s|%s|%s\n' "$model" "$effort" "$prompt" >> "$session.meta"
if [ -n "${FAKE_PI_ENV_LOG:-}" ]; then
    {
        printf 'name=%s\n' "$name"
        printf 'extension=%s\n' "$extensions"
        printf 'exclude_tools=%s\n' "$exclude_tools"
        printf 'session_name=%s\n' "${PI_SUBAGENT_INTERCOM_SESSION_NAME:-}"
        printf 'target=%s\n' "${PI_SUBAGENT_ORCHESTRATOR_TARGET:-}"
        printf 'run_id=%s\n' "${PI_SUBAGENT_RUN_ID:-}"
        printf 'agent=%s\n' "${PI_SUBAGENT_CHILD_AGENT:-}"
        printf 'index=%s\n' "${PI_SUBAGENT_CHILD_INDEX:-}"
        printf -- '---\n'
    } >> "$FAKE_PI_ENV_LOG"
fi
if grep -q 'FAIL' "$prompt"; then
    printf 'partial response\n'
    printf 'fake pi failure\n' >&2
    exit 7
fi
# Arc stage behaviors: the planner writes plan.md, the worker ticks the next
# unchecked node, the critic answers PASS only when every node is ticked.
plan_target=$(sed -n 's/^Write the plan to exactly this path: //p' "$prompt" | head -n 1)
if [ -n "$plan_target" ]; then
    {
        printf '# Plan\n'
        printf -- '- [ ] 1. first node - done when first ok\n'
        printf -- '- [ ] 2. second node - done when second ok\n'
    } > "$plan_target"
fi
worker_plan=$(sed -n 's|^Work the plan at \(.*\)\.$|\1|p' "$prompt" | head -n 1)
if [ -n "$worker_plan" ] && [ -f "$worker_plan" ]; then
    awk 'BEGIN { t = 0 } { if (!t && $0 ~ /^- \[ \]/) { sub(/^- \[ \]/, "- [x]"); t = 1 } print }' \
        "$worker_plan" > "$worker_plan.tmp"
    mv "$worker_plan.tmp" "$worker_plan"
fi
printf 'fake response\n'
if [ -n "${FAKE_PI_GATE:-}" ]; then
    while [ ! -e "$FAKE_PI_GATE" ]; do sleep 1; done
fi
FAKE_PI
chmod +x "$tmp/bin/pi"

cat > "$tmp/bin/tmux" <<'FAKE_TMUX'
#!/bin/sh
set -eu
state=${FAKE_TMUX_STATE:?}
log=${FAKE_TMUX_LOG:?}
printf '%s\n' "$*" >> "$log"
[ -f "$state/windows" ] || : > "$state/windows"
[ -f "$state/panes" ] || : > "$state/panes"
cmd_name=$1
shift
case "$cmd_name" in
    has-session) exit 0 ;;
    list-windows)
        awk '{ print "@" NR " " $0 }' "$state/windows"
        exit 0 ;;
    list-panes)
        # Report each pane tracked for the target window, dead (1) once the
        # backgrounded pid recorded at creation time is no longer running.
        target=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -t) target=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        while IFS=' ' read -r pane win pid; do
            [ "$win" = "$target" ] || continue
            if kill -0 "$pid" 2>/dev/null; then dead=0; else dead=1; fi
            printf '%s %s\n' "$pane" "$dead"
        done < "$state/panes"
        exit 0 ;;
    kill-pane)
        target=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -t) target=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        awk -v id="$target" '$1 != id' "$state/panes" > "$state/panes.tmp"
        mv "$state/panes.tmp" "$state/panes"
        exit 0 ;;
    list-sessions) printf 'fake-session\n' ;;
    new-window|split-window|new-session)
        name=
        winarg=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -n) name=$2; shift 2 ;;
                -s) name=$2; shift 2 ;;
                -t) winarg=$2; shift 2 ;;
                -d|-P) shift ;;
                -F|-c|-e) shift 2 ;;
                *) break ;;
            esac
        done
        if [ "$cmd_name" = new-window ] || [ "$cmd_name" = new-session ]; then
            [ -n "$name" ] || exit 9
            if grep -Fqx "$name" "$state/windows"; then
                exit 9
            fi
            printf '%s\n' "$name" >> "$state/windows"
            winarg="@$(wc -l < "$state/windows" | tr -d ' ')"
        fi
        sh -c "$*" </dev/null >"$state/pane-out" 2>&1 &
        bgpid=$!
        pane="%$(( $(wc -l < "$state/panes" | tr -d ' ') + 1 ))"
        printf '%s %s %s\n' "$pane" "$winarg" "$bgpid" >> "$state/panes"
        printf '%s %s\n' "$pane" "$bgpid"
        exit 0 ;;
    display-message) printf '@1\n' ;;
    set-option|select-layout|select-pane) exit 0 ;;
    *) exit 0 ;;
esac
FAKE_TMUX
chmod +x "$tmp/bin/tmux"

# Same fake pi, but the tmux here reports no running server so the helper must
# fall back to headless children.
cp "$tmp/bin/pi" "$tmp/bin-notmux/pi"
cat > "$tmp/bin-notmux/tmux" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$tmp/bin-notmux/tmux"

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
export FAKE_INTERCOM_EXT=$tmp/intercom.ts
export FAKE_WATCH_EXT=$skill_dir/scripts/pi-subagent-watch-exit.ts
export PI_SUBAGENT_INTERCOM_EXTENSION=$tmp/intercom.ts
export PI_SESSION_ID=session-abcdef1234567890
export FAKE_PI_ENV_LOG=$tmp/pi-env.log
export FAKE_TMUX_STATE=$tmp/tmux-state
export FAKE_TMUX_LOG=$tmp/tmux.log

printf 'Do the task.\n' > task.md
output=$(PATH="$tmp/bin:$PATH" FAKE_PI_GATE="$tmp/gate" "$helper" start --async --agent researcher task.md)
id=$(value id "$output")
result=$(value result "$output")
exit_file=$(value exit_code "$output")
[ -n "$id" ] || fail 'start did not return an id'
[ "$(value window "$output")" = subagents ] || fail 'start did not report the watch window'
[ -d ".pi-subagent-runs/$id" ] || fail 'task-specific session directory missing'
exclude=$(git rev-parse --git-path info/exclude)
grep -Fqx '/.pi-subagent-runs/' "$exclude" || fail 'local Git exclude was not updated'
[ ! -e .gitignore ] || fail 'start created a tracked .gitignore'
[ ! -e "$result" ] || fail 'async result was published before Pi exited'
[ ! -e "$exit_file" ] || fail 'exit marker appeared before Pi exited'
grep -q -- '-n subagents' "$tmp/tmux.log" || fail 'watch window was not created'
grep -q 'target=subagent-chat-abcdef1234567890' "$tmp/pi-env.log" || fail 'orchestrator target was not derived from the parent session id'
grep -q "run_id=$id" "$tmp/pi-env.log" || fail 'bridge metadata did not carry the run id'
grep -q 'agent=researcher' "$tmp/pi-env.log" || fail 'bridge metadata did not carry the agent name'
grep -q 'index=0' "$tmp/pi-env.log" || fail 'bridge metadata did not carry the child index'
grep -q "session_name=researcher-$id" "$tmp/pi-env.log" || fail 'child did not receive its intercom session name'
grep -q "extension=$tmp/intercom.ts" "$tmp/pi-env.log" || fail 'child did not load the intercom extension'
: > "$tmp/gate"
PATH="$tmp/bin:$PATH" "$helper" wait "$id" >/dev/null
[ "$(cat "$exit_file")" = 0 ] || fail 'async turn did not succeed'
[ "$(cat "$result")" = 'fake response' ] || fail 'result artifact did not contain final response'

session=$(value session "$output")
printf 'Continue the task.\n' > follow-up.md
follow_output=$(PATH="$tmp/bin:$PATH" "$helper" follow-up "$id" follow-up.md)
[ "$(value session "$follow_output")" = "$session" ] || fail 'follow-up changed the session path'
[ "$(wc -l < "$session.meta" | tr -d ' ')" = 2 ] || fail 'follow-up did not reuse the session'
[ "$(cut -d '|' -f 1,2 "$session.meta" | uniq | wc -l | tr -d ' ')" = 1 ] || fail 'follow-up did not reuse the model profile'
[ "$(cut -d '|' -f 1,2 "$session.meta" | head -n 1)" = 'github-copilot/gpt-5.6-luna|max' ] || fail 'default model profile was not used'

printf 'Second task.\n' > second.md
second_output=$(PATH="$tmp/bin:$PATH" "$helper" start --async --orchestrator-target named-supervisor second.md)
second_id=$(value id "$second_output")
grep -q '^split-window ' "$tmp/tmux.log" || fail 'second subagent did not split into the existing watch window'
[ "$(wc -l < "$tmp/tmux-state/windows" | tr -d ' ')" = 1 ] || fail 'second subagent created a second watch window'
grep -q 'target=named-supervisor' "$tmp/pi-env.log" || fail 'explicit orchestrator target was not passed to the child'
grep -q "index=1" "$tmp/pi-env.log" || fail 'second child did not get the next child index'
grep -q "session_name=worker-$second_id" "$tmp/pi-env.log" || fail 'default agent name was not used'
PATH="$tmp/bin:$PATH" "$helper" wait "$second_id" >/dev/null
[ "$(wc -l < "$tmp/tmux-state/panes" | tr -d ' ')" = 1 ] || fail 'earlier finished subagent panes were not swept before the next launch'
: > "$tmp/gate2"

printf 'Continue with a replacement profile.\n' > replacement.md
PATH="$tmp/bin:$PATH" "$helper" follow-up "$id" --model custom/test --effort low replacement.md >/dev/null
[ "$(tail -n 1 "$session.meta" | cut -d '|' -f 1,2)" = 'custom/test|low' ] || fail 'complete replacement model profile was not persisted'
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
[ "$(wc -l < "$tmp/tmux-state/panes" | tr -d ' ')" = 0 ] || fail 'list did not sweep finished subagent panes'

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

printf 'Headless task.\n' > headless.md
headless_output=$(PATH="$tmp/bin-notmux:$PATH" "$helper" start headless.md 2>"$tmp/headless.err")
headless_id=$(value id "$headless_output")
grep -q 'headless' "$tmp/headless.err" || fail 'missing tmux server did not produce a notice'
[ -f ".pi-subagent-runs/$headless_id/turn-001.result.md" ] || fail 'headless foreground child did not publish its result'

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

# --- arc: plan -> work -> critique ---
git -c user.email=arc@test -c user.name=arc commit --allow-empty -qm init

printf 'Build a small utility library.\n' > arc-task.md
plan_output=$(PATH="$tmp/bin:$PATH" "$helper" plan arc-task.md)
plan_id=$(value id "$plan_output")
plan_file=.pi-subagent-runs/$plan_id/plan.md
[ -f "$plan_file" ] || fail 'planner did not write plan.md'
plan_prompt=.pi-subagent-runs/$plan_id/turn-001.prompt.md
grep -q 'PLANNER stage' "$plan_prompt" || fail 'plan turn did not use the planner boundary'
grep -q "Write the plan to exactly this path: .*$plan_id/plan.md" "$plan_prompt" || fail 'planner prompt did not carry the plan path'
[ -f ".pi-subagent-runs/$plan_id/base-ref" ] || fail 'plan stage did not record the base git ref'
plan_session=$(value session "$plan_output")
[ "$(tail -n 1 "$plan_session.meta" | cut -d '|' -f 1,2)" = 'github-copilot/grok-4.6|xhigh' ] || fail 'plan did not use the planner profile'
grep -q 'agent=planner' "$tmp/pi-env.log" || fail 'planner child did not get the planner agent name'
PATH="$tmp/bin:$PATH" "$helper" status "$plan_id" | grep -q 'plan=0/2' || fail 'status did not report initial plan progress'
[ "$(grep -c 'exclude_tools=edit,write' "$tmp/pi-env.log")" = 1 ] || fail 'planner child was not restricted to read-only tools'

work_output=$(PATH="$tmp/bin:$PATH" "$helper" work "$plan_id")
[ "$(value id "$work_output")" = "$plan_id" ] || fail 'work did not reuse the plan session'
grep -q 'WORKER stage' ".pi-subagent-runs/$plan_id/turn-002.prompt.md" || fail 'work turn did not use the worker boundary'
grep -q '^- \[x\] 1\.' "$plan_file" || fail 'worker did not tick the first node'
grep -q 'agent=worker' "$tmp/pi-env.log" || fail 'work did not relabel the child as the worker agent'
[ "$(tail -n 1 "$plan_session.meta" | cut -d '|' -f 1,2)" = 'github-copilot/gpt-5.6-luna|max' ] || fail 'work did not default to the commodity worker profile'
PATH="$tmp/bin:$PATH" "$helper" status "$plan_id" | grep -q 'plan=1/2' || fail 'plan progress did not advance after work'
[ "$(grep -c 'exclude_tools=edit,write' "$tmp/pi-env.log")" = 1 ] || fail 'worker turn was incorrectly restricted to read-only tools'
PATH="$tmp/bin:$PATH" "$helper" work "$plan_id" >/dev/null
PATH="$tmp/bin:$PATH" "$helper" status "$plan_id" | grep -q 'plan=2/2' || fail 'second work turn did not tick the second node'
if PATH="$tmp/bin:$PATH" "$helper" work missing-id >/dev/null 2>&1; then
    fail 'work accepted a missing session'
fi
if PATH="$tmp/bin:$PATH" "$helper" work "$second_id" >/dev/null 2>&1; then
    fail 'work accepted a session without a plan'
fi

critique_output=$(PATH="$tmp/bin:$PATH" "$helper" critique "$plan_id")
critique_id=$(value id "$critique_output")
[ -n "$critique_id" ] && [ "$critique_id" != "$plan_id" ] || fail 'critique did not start a fresh session'
critique_prompt_file=.pi-subagent-runs/$critique_id/turn-001.prompt.md
grep -q 'CRITIC stage' "$critique_prompt_file" || fail 'critique turn did not use the critic boundary'
grep -q "Plan: .*$plan_id/plan.md" "$critique_prompt_file" || fail 'critique prompt did not name the plan file'
critique_session=$(value session "$critique_output")
grep -q 'agent=critic' "$tmp/pi-env.log" || fail 'critic child did not get the critic agent name'
[ "$(tail -n 1 "$critique_session.meta" | cut -d '|' -f 1,2)" = 'github-copilot/grok-4.6|xhigh' ] || fail 'critique did not default to the frontier critic profile'
[ "$(grep -c 'exclude_tools=edit,write' "$tmp/pi-env.log")" = 2 ] || fail 'critic child was not restricted to read-only tools'
grep -q '^PASS' "$(value result "$critique_output")" || fail 'critic did not PASS a completed plan'

printf 'Another arc.\n' > arc-task2.md
plan2_output=$(PATH="$tmp/bin:$PATH" "$helper" plan arc-task2.md)
plan2_id=$(value id "$plan2_output")
PATH="$tmp/bin:$PATH" "$helper" work "$plan2_id" >/dev/null
critique2_output=$(PATH="$tmp/bin:$PATH" "$helper" critique "$plan2_id")
grep -q '^FIX:' "$(value result "$critique2_output")" || fail 'critic did not flag an incomplete plan'

printf 'ok\n'

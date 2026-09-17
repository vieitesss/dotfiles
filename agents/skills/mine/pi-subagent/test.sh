#!/bin/sh
set -eu

skill_dir=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
helper=$skill_dir/scripts/pi-subagent.sh
# /tmp, not $TMPDIR: macOS TMPDIR paths are deep enough to push the herdr
# launcher path over the short-typed-command threshold the suite asserts on.
tmp=$(mktemp -d "/tmp/pi-subagent-test.XXXXXX")
# Supervisor-side pane for the fake tmux world: display-message -t $TMUX_PANE
# resolves through it, and killing it on exit leaves no stray sleep behind.
sleep 300 &
sup_sleep=$!
# The real-tmux section below records its private socket in RL_SOCK; this
# backstop kills only that server (never the default socket) if the suite
# exits early.
trap 'kill $sup_sleep 2>/dev/null; [ -n "${RL_SOCK:-}" ] && command -v tmux >/dev/null 2>&1 && tmux -L "$RL_SOCK" kill-server >/dev/null 2>&1; rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/bin" "$tmp/bin-notmux" "$tmp/bin-notmux2" "$tmp/work" "$tmp/tmux-state"

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
        printf 'herdr_inner=%s\n' "${PI_SUBAGENT_HERDR_INNER:-}"
        printf 'herdr_pane=%s\n' "${PI_SUBAGENT_HERDR_PANE:-}"
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
if [ -n "${FAKE_NESTED_HELPER:-}" ] && grep -q 'NESTED-HELPER' "$prompt"; then
    printf 'Nested grandchild task.\n' > "$FAKE_NESTED_PROMPT"
    "$FAKE_NESTED_HELPER" start "$FAKE_NESTED_PROMPT" >"$FAKE_NESTED_OUT" 2>"$FAKE_NESTED_ERR" || true
fi
if [ -n "${FAKE_PI_GATE:-}" ]; then
    # Bounded wait: a missing gate must fail the suite within a minute,
    # never hang it forever (a stopped child never reaches this point).
    waited=0
    while [ ! -e "$FAKE_PI_GATE" ] && [ "$waited" -lt 60 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    if [ ! -e "$FAKE_PI_GATE" ]; then
        printf 'fake pi gate timeout
' >&2
        exit 99
    fi
fi
FAKE_PI
chmod +x "$tmp/bin/pi"

cat > "$tmp/bin/tmux" <<'FAKE_TMUX'
#!/bin/sh
# Deterministic fake modelling the real-tmux behaviors the watcher depends
# on: a window vanishes with its last pane, duplicate window names are
# allowed, unknown targets fail, and ids are never hard-coded. Anything the
# helper must never do — including new-session (no dedicated sessions) and
# has-session/list-sessions (no longer used) — fails loudly. State files,
# seeded by the test below:
#   sessions "<session_id> <session_name>"
#   windows  "<window_id> <session_id> <window_name>"
#   panes    "<pane_id> <window_id> <pid>"
#   winopts  "<window_id> <option> <value>"
#   next-pane / next-window hold id counters (ids are never reused).
# A pane lists as dead (1) once its pid is gone when its window has
# remain-on-exit on; without it the pane is simply gone. Test hook:
# creating $state/fail-split-once makes the next split-window delete its
# target window first and fail with the real "can't find window" error.
set -eu
state=${FAKE_TMUX_STATE:?}
log=${FAKE_TMUX_LOG:?}
printf '%s\n' "$*" >> "$log"
cur_session=${FAKE_TMUX_SESSION:-fake-session}
cur_session_id=${FAKE_TMUX_SESSION_ID:-'$1'}

next_id() {
    n=$(cat "$state/next-$1")
    printf '%s\n' "$((n + 1))" > "$state/next-$1"
    case $1 in
        pane) printf '%%%s\n' "$n" ;;
        window) printf '@%s\n' "$n" ;;
    esac
}

expand_fmt() {
    # $1 format; $2 pane; $3 pid; $4 dead; $5 window; $6 window name;
    # $7 session id; $8 session name. Test ids/names never contain & or |.
    printf '%s\n' "$1" | sed -e "s/#{pane_id}/$2/g" -e "s/#{pane_pid}/$3/g" \
        -e "s/#{pane_dead}/$4/g" -e "s/#{window_id}/$5/g" -e "s/#{window_name}/$6/g" \
        -e "s/#{session_id}/$7/g" -e "s/#{session_name}/$8/g"
}

find_pane() { awk -v id="$1" '$1 == id { print $2, $3; exit }' "$state/panes"; }
find_window() { awk -v id="$1" '$1 == id { print $2, $3; exit }' "$state/windows"; }
find_session() { awk -v t="$1" '$1 == t || $2 == t { print $1, $2; exit }' "$state/sessions"; }
opt_on() { grep -Fqx "$1 $2 on" "$state/winopts" 2>/dev/null; }

cmd_name=$1
shift
case "$cmd_name" in
    display-message)
        target=; fmt=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -p) shift ;;
                -F) fmt=$2; shift 2 ;;
                -t) target=$2; shift 2 ;;
                -*) printf 'fake tmux: bad flag %s\n' "$1" >&2; exit 9 ;;
                *) fmt=$1; shift ;;
            esac
        done
        pane=; pid=; dead=; win=; wname=; sess=; sname=
        if [ -z "$target" ]; then
            sess=$cur_session_id; sname=$cur_session
        elif prow=$(find_pane "$target") && [ -n "$prow" ]; then
            win=${prow%% *}; pid=${prow#* }
            wrow=$(find_window "$win")
            sess=${wrow%% *}; wname=${wrow#* }
            sname=$(awk -v id="$sess" '$1 == id { print $2; exit }' "$state/sessions")
        elif wrow=$(find_window "$target") && [ -n "$wrow" ]; then
            win=$target; sess=${wrow%% *}; wname=${wrow#* }
            sname=$(awk -v id="$sess" '$1 == id { print $2; exit }' "$state/sessions")
        elif srow=$(find_session "$target") && [ -n "$srow" ]; then
            sess=${srow%% *}; sname=${srow#* }
        else
            exit 1
        fi
        expand_fmt "$fmt" "$pane" "$pid" "$dead" "$win" "$wname" "$sess" "$sname"
        exit 0
        ;;
    list-windows)
        target=; fmt=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -t) target=$2; shift 2 ;;
                -F) fmt=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        srow=$(find_session "$target")
        [ -n "$srow" ] || { printf "can't find session: %s\n" "$target" >&2; exit 1; }
        sess=${srow%% *}
        while read -r wid sid wname; do
            [ "$sid" = "$sess" ] || continue
            present=false
            while read -r p w pid; do
                [ "$w" = "$wid" ] || continue
                if kill -0 "$pid" 2>/dev/null || opt_on "$wid" remain-on-exit; then
                    present=true; break
                fi
            done < "$state/panes"
            $present || continue
            expand_fmt "$fmt" "" "" "" "$wid" "$wname" "$sess" ""
        done < "$state/windows"
        exit 0
        ;;
    list-panes)
        target=; fmt=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -t) target=$2; shift 2 ;;
                -F) fmt=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        [ -n "$(find_window "$target")" ] || { printf "can't find window: %s\n" "$target" >&2; exit 1; }
        while read -r pane win pid; do
            [ "$win" = "$target" ] || continue
            if kill -0 "$pid" 2>/dev/null; then dead=0
            elif opt_on "$win" remain-on-exit; then dead=1
            else continue; fi
            expand_fmt "$fmt" "$pane" "$pid" "$dead" "$win" "" "" ""
        done < "$state/panes"
        exit 0
        ;;
    kill-pane)
        target=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -t) target=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        prow=$(find_pane "$target")
        [ -n "$prow" ] || { printf "can't find pane: %s\n" "$target" >&2; exit 1; }
        win=${prow%% *}
        awk -v id="$target" '$1 != id' "$state/panes" > "$state/panes.tmp"
        mv "$state/panes.tmp" "$state/panes"
        if ! awk -v w="$win" '$2 == w { found=1 } END { exit !found }' "$state/panes"; then
            awk -v w="$win" '$1 != w' "$state/windows" > "$state/windows.tmp"
            mv "$state/windows.tmp" "$state/windows"
            awk -v w="$win" '$1 != w' "$state/winopts" > "$state/winopts.tmp"
            mv "$state/winopts.tmp" "$state/winopts"
        fi
        exit 0
        ;;
    new-window|split-window)
        name=; winarg=; fmt=; envargs=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -d|-P) shift ;;
                -F) fmt=$2; shift 2 ;;
                -c) shift 2 ;;
                -e) envargs="$envargs $2"; shift 2 ;;
                -n) name=$2; shift 2 ;;
                -s) printf 'fake tmux: -s (dedicated sessions) is unsupported\n' >&2; exit 9 ;;
                -t) winarg=$2; shift 2 ;;
                --) shift; break ;;
                -*) printf 'fake tmux: bad flag %s\n' "$1" >&2; exit 9 ;;
                *) break ;;
            esac
        done
        cmd="$*"
        if [ "$cmd_name" = new-window ]; then
            [ -n "$name" ] || exit 9
            sessname=${winarg%:}
            sessid=$(awk -v n="$sessname" '$1 == n || $2 == n { print $1; exit }' "$state/sessions")
            [ -n "$sessid" ] || { printf "can't find session: %s\n" "$sessname" >&2; exit 1; }
            winid=$(next_id window)
            printf '%s %s %s\n' "$winid" "$sessid" "$name" >> "$state/windows"
        else
            if [ -e "$state/fail-split-once" ]; then
                # The target window vanishes (closed elsewhere) first.
                rm -f "$state/fail-split-once"
                awk -v id="$winarg" '$1 != id' "$state/windows" > "$state/windows.tmp"
                mv "$state/windows.tmp" "$state/windows"
                awk -v id="$winarg" '$2 != id' "$state/panes" > "$state/panes.tmp"
                mv "$state/panes.tmp" "$state/panes"
                awk -v id="$winarg" '$1 != id' "$state/winopts" > "$state/winopts.tmp"
                mv "$state/winopts.tmp" "$state/winopts"
                printf "can't find window: %s\n" "$winarg" >&2
                exit 1
            fi
            [ -n "$(find_window "$winarg")" ] || { printf "can't find window: %s\n" "$winarg" >&2; exit 1; }
            winid=$winarg; sessid=
        fi
        # shellcheck disable=SC2086 # -e VAR=val words split on purpose
        env $envargs sh -c "$cmd" </dev/null >>"$state/pane-out" 2>&1 &
        bgpid=$!
        paneid=$(next_id pane)
        printf '%s %s %s\n' "$paneid" "$winid" "$bgpid" >> "$state/panes"
        wrow=$(find_window "$winid"); wname=${wrow#* }
        expand_fmt "$fmt" "$paneid" "$bgpid" "" "$winid" "$wname" "$sessid" ""
        exit 0
        ;;
    respawn-pane)
        envargs=; dokill=false; target=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -e) envargs="$envargs $2"; shift 2 ;;
                -k) dokill=true; shift ;;
                -t) target=$2; shift 2 ;;
                -c) shift 2 ;;
                --) shift; break ;;
                -*) printf 'fake tmux: bad flag %s\n' "$1" >&2; exit 9 ;;
                *) break ;;
            esac
        done
        cmd="$*"
        prow=$(find_pane "$target")
        [ -n "$prow" ] || { printf "can't find pane: %s\n" "$target" >&2; exit 1; }
        oldpid=${prow#* }
        $dokill && kill "$oldpid" 2>/dev/null || :
        # shellcheck disable=SC2086 # -e VAR=val words split on purpose
        env $envargs sh -c "$cmd" </dev/null >>"$state/pane-out" 2>&1 &
        bgpid=$!
        awk -v id="$target" -v pid="$bgpid" '{ if ($1 == id) $3 = pid; print }' \
            "$state/panes" > "$state/panes.tmp"
        mv "$state/panes.tmp" "$state/panes"
        exit 0
        ;;
    set-option)
        target=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -w) shift ;;
                -t) target=$2; shift 2 ;;
                -g) printf 'fake tmux: -g (global options) is unsupported\n' >&2; exit 9 ;;
                *) break ;;
            esac
        done
        opt=$1; val=$2
        [ -n "$(find_window "$target")" ] || { printf "can't find window: %s\n" "$target" >&2; exit 1; }
        awk -v w="$target" -v o="$opt" '$1 != w || $2 != o' "$state/winopts" > "$state/winopts.tmp"
        mv "$state/winopts.tmp" "$state/winopts"
        printf '%s %s %s\n' "$target" "$opt" "$val" >> "$state/winopts"
        exit 0
        ;;
    show-options)
        target=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -w) shift ;;
                -t) target=$2; shift 2 ;;
                *) break ;;
            esac
        done
        opt=$1
        val=$(awk -v w="$target" -v o="$opt" '$1 == w && $2 == o { print $3; exit }' "$state/winopts")
        [ -n "$val" ] || exit 1
        printf '%s %s\n' "$opt" "$val"
        exit 0
        ;;
    select-layout|select-pane) exit 0 ;;
    *) printf 'fake tmux: unsupported command: %s\n' "$cmd_name" >&2; exit 9 ;;
esac
FAKE_TMUX
chmod +x "$tmp/bin/tmux"

# Seed the fake world: the supervisor sits in window @1 (pane %0, live) of
# fake-session ($1); other-session ($2) owns a marked same-named window the
# helper must never touch. Ids continue from the counters (never reused).
printf '$1 fake-session\n$2 other-session\n' > "$tmp/tmux-state/sessions"
printf '@1 $1 editor\n@9 $2 subagents\n' > "$tmp/tmux-state/windows"
printf '%%0 @1 %s\n%%8 @9 %s\n' "$sup_sleep" "$sup_sleep" > "$tmp/tmux-state/panes"
printf '@9 @pi-subagent-watch 1\n@9 remain-on-exit on\n' > "$tmp/tmux-state/winopts"
printf '9\n' > "$tmp/tmux-state/next-pane"
printf '10\n' > "$tmp/tmux-state/next-window"
: > "$tmp/tmux-state/pane-out"

# Same fake pi, but the tmux here reports no running server so the helper must
# fall back to headless children.
cp "$tmp/bin/pi" "$tmp/bin-notmux/pi"
cat > "$tmp/bin-notmux/tmux" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$tmp/bin-notmux/tmux"

# Same again, but with NO tmux at all: only the fake pi plus symlinks to the
# system tools a headless start needs, so command -v tmux fails everywhere.
cp "$tmp/bin/pi" "$tmp/bin-notmux2/pi"
# A headless start still needs the POSIX basics the helper is written
# against (including dirname/basename/head/tail for self-location and the
# watch-line replay); only tmux itself is absent here.
for tool in mkdir cat rm mv git sed grep cut sleep mktemp env dirname basename head tail; do
    tool_path=$(command -v "$tool") || fail "test setup: $tool not found"
    ln -s "$tool_path" "$tmp/bin-notmux2/$tool"
done

git init -q "$tmp/work"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

value() {
    key=$1
    printf '%s\n' "$2" | awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

# Fake-state inspectors. Session ids are literal ($1 = fake-session).
win_in() {
    awk -v s="$1" -v n="$2" '$2 == s && $3 == n { print $1; exit }' "$tmp/tmux-state/windows"
}

panes_in() {
    awk -v w="$1" '$2 == w { print $1 }' "$tmp/tmux-state/panes"
}

watch_pane_of() {
    pane_sess=${2:-fake-session}
    printf '%s\n' "$1" | sed -n "s/^watch=tmux tmux_session=$pane_sess window=subagents pane=//p"
}

wait_for_grep() {
    # Poll until $2 appears in $1 (bound 30s). Async starts return as soon
    # as the turn pid file exists, which can precede the child's own
    # artifact writes by milliseconds; never assert on those unguarded.
    tries=0
    while [ "$tries" -lt 30 ]; do
        if [ -e "$1" ] && grep -q "$2" "$1" 2>/dev/null; then
            return 0
        fi
        sleep 1
        tries=$((tries + 1))
    done
    return 1
}

cd "$tmp/work"
export FAKE_INTERCOM_EXT=$tmp/intercom.ts
export FAKE_WATCH_EXT=$skill_dir/scripts/pi-subagent-watch-exit.ts
export PI_SUBAGENT_INTERCOM_EXTENSION=$tmp/intercom.ts
export PI_SESSION_ID=session-abcdef1234567890
export FAKE_PI_ENV_LOG=$tmp/pi-env.log
export FAKE_TMUX_STATE=$tmp/tmux-state
export FAKE_TMUX_LOG=$tmp/tmux.log
# Isolate the suite from the invoking shell: the helper must only ever see
# the fake world, never the user's real tmux server, session, or pane.
export TMUX=fake TMUX_PANE=%0
# A live Herdr session exports HERDR_ENV=1; existing tmux/headless cases
# must not take that branch or talk to the real CLI. Inner pane-runs set
# PI_SUBAGENT_HERDR_INNER; if this suite is itself a Herdr-spawned child,
# drop that marker so the tests control the branch themselves.
unset HERDR_ENV
unset PI_SUBAGENT_HERDR_INNER
# The suite must never invoke a real agent: drop any inherited pi override
# so every pane child resolves through the fakes on PATH (or the explicit
# per-section pins below). Process-local only; the caller's env is untouched.
unset PI_SUBAGENT_PI

printf 'Do the task.\n' > task.md
output=$(PATH="$tmp/bin:$PATH" FAKE_PI_GATE="$tmp/gate" "$helper" start --async --agent researcher task.md)
id=$(value id "$output")
result=$(value result "$output")
exit_file=$(value exit_code "$output")
[ -n "$id" ] || fail 'start did not return an id'
printf '%s\n' "$output" | grep -q '^watch=tmux tmux_session=fake-session window=subagents pane=%' || fail 'start did not report its watch pane truthfully'
if printf '%s\n' "$output" | grep -q '^window='; then fail 'start emitted a bare window= line'; fi
[ -d ".pi-subagent-runs/$id" ] || fail 'task-specific session directory missing'
exclude=$(git rev-parse --git-path info/exclude)
grep -Fqx '/.pi-subagent-runs/' "$exclude" || fail 'local Git exclude was not updated'
[ ! -e .gitignore ] || fail 'start created a tracked .gitignore'
[ ! -e "$result" ] || fail 'async result was published before Pi exited'
[ ! -e "$exit_file" ] || fail 'exit marker appeared before Pi exited'
grep -q -- '-n subagents' "$tmp/tmux.log" || fail 'watch window was not created'
wait_for_grep "$tmp/pi-env.log" "run_id=$id" || fail 'child never logged bridge metadata'
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
[ "$(cut -d '|' -f 1,2 "$session.meta" | head -n 1)" = 'opencode-go/deepseek-v4.1-flash|max' ] || fail 'default model profile was not used'
# Fast exit keeps its pane: this foreground child finished in milliseconds,
# yet retention was set before it started, so the pane stays as dead.
watch_win=$(win_in '$1' subagents)
[ -n "$watch_win" ] || fail 'no owned watch window after follow-up'
fu_pane=$(watch_pane_of "$follow_output")
[ -n "$fu_pane" ] || fail 'follow-up did not report its watch pane'
PATH="$tmp/bin:$PATH" tmux list-panes -t "$watch_win" -F '#{pane_id}:#{pane_dead}' | grep -q "^$fu_pane:1$" || fail 'fast-exit pane was not retained as dead'

printf 'Second task.\n' > second.md
second_output=$(PATH="$tmp/bin:$PATH" "$helper" start --async --orchestrator-target named-supervisor second.md)
second_id=$(value id "$second_output")
printf '%s\n' "$second_output" | grep -q '^watch=tmux tmux_session=fake-session window=subagents pane=%' || fail 'second start did not report its watch pane'
wait_for_grep "$tmp/pi-env.log" "run_id=$second_id" || fail 'second child never logged bridge metadata'
grep -q '^split-window ' "$tmp/tmux.log" || fail 'second subagent did not split into the existing watch window'
[ "$(grep -c ' \$1 subagents$' "$tmp/tmux-state/windows")" = 1 ] || fail 'second subagent created a second watch window'
grep -q 'target=named-supervisor' "$tmp/pi-env.log" || fail 'explicit orchestrator target was not passed to the child'
grep -q "index=1" "$tmp/pi-env.log" || fail 'second child did not get the next child index'
grep -q "session_name=implementer-$second_id" "$tmp/pi-env.log" || fail 'default agent name was not used'
PATH="$tmp/bin:$PATH" "$helper" wait "$second_id" >/dev/null
[ "$(panes_in "$watch_win" | wc -l | tr -d ' ')" = 1 ] || fail 'earlier finished subagent panes were not swept before the next launch'
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
# list sweeps finished panes but retains the final completed pane as anchor.
[ "$(panes_in "$watch_win" | wc -l | tr -d ' ')" = 1 ] || fail 'list did not retain the final completed pane'
PATH="$tmp/bin:$PATH" tmux list-panes -t "$watch_win" -F '#{pane_dead}' | grep -q '^1$' || fail 'retained anchor pane is not a finished one'

# --- watch behavior: last-pane, retry, concurrency, scoping, ownership ---
# Sequential last-pane launch: the window holds only a finished pane, so the
# next launch must split fresh (create-before-sweep). Against this fake, a
# sweep-first order would hit "can't find window" and fail — success here
# is the regression proof.
prev_pane=$(panes_in "$watch_win")
[ "$(printf '%s\n' "$prev_pane" | wc -l | tr -d ' ')" = 1 ] || fail 'last-pane setup did not yield one finished pane'
printf 'Last pane task.\n' > lastpane.md
last_output=$(PATH="$tmp/bin:$PATH" "$helper" start lastpane.md)
last_pane=$(watch_pane_of "$last_output")
[ -n "$last_pane" ] || fail 'last-pane launch did not report its watch pane'
[ "$last_pane" != "$prev_pane" ] || fail 'last-pane launch reused the finished pane'
[ "$(panes_in "$watch_win" | wc -l | tr -d ' ')" = 1 ] || fail 'last-pane launch left more than one pane'

# Stale-target recovery: the next split fails once with a vanished window;
# the helper must recreate once and still succeed (bounded retry, no silent
# headless fallback).
printf 'Retry task.\n' > retry.md
log_before=$(wc -l < "$tmp/tmux.log")
: > "$tmp/tmux-state/fail-split-once"
retry_output=$(PATH="$tmp/bin:$PATH" "$helper" start retry.md)
[ -n "$(watch_pane_of "$retry_output")" ] || fail 'stale-target retry did not report its watch pane'
tail -n +"$((log_before + 1))" "$tmp/tmux.log" | awk '/^split-window/{s=1; next} s && /^new-window/{ok=1} END{exit !ok}' || fail 'stale-target retry did not recreate after the failed split'
[ "$(grep -c ' \$1 subagents$' "$tmp/tmux-state/windows")" = 1 ] || fail 'stale-target retry left a duplicated window'
[ -f ".pi-subagent-runs/$(value id "$retry_output")/turn-001.result.md" ] || fail 'retried child did not publish its result'
# The retry recreated the window, so re-resolve its id for later checks.
watch_win=$(win_in '$1' subagents)
[ -n "$watch_win" ] || fail 'no owned watch window after retry'

# Concurrent launches serialize onto one owned window: both children gate on
# the same file, so both panes are live at once, then both finish.
printf 'Concurrent one.\n' > conc1.md
printf 'Concurrent two.\n' > conc2.md
rm -f "$tmp/cgate"
conc1_output=$(PATH="$tmp/bin:$PATH" FAKE_PI_GATE="$tmp/cgate" "$helper" start --async conc1.md)
conc1_id=$(value id "$conc1_output")
conc2_output=$(PATH="$tmp/bin:$PATH" FAKE_PI_GATE="$tmp/cgate" "$helper" start --async conc2.md)
conc2_id=$(value id "$conc2_output")
[ -n "$(watch_pane_of "$conc1_output")" ] || fail 'concurrent launch 1 reported no watch pane'
[ -n "$(watch_pane_of "$conc2_output")" ] || fail 'concurrent launch 2 reported no watch pane'
[ "$(panes_in "$watch_win" | wc -l | tr -d ' ')" = 2 ] || fail 'concurrent launches did not hold two live panes'
[ "$(grep -c ' \$1 subagents$' "$tmp/tmux-state/windows")" = 1 ] || fail 'concurrent launches created duplicate windows'
: > "$tmp/cgate"
PATH="$tmp/bin:$PATH" "$helper" wait "$conc1_id" >/dev/null
PATH="$tmp/bin:$PATH" "$helper" wait "$conc2_id" >/dev/null
[ "$(cat ".pi-subagent-runs/$conc1_id/turn-001.exit-code")" = 0 ] || fail 'concurrent child 1 did not succeed'
[ "$(cat ".pi-subagent-runs/$conc2_id/turn-001.exit-code")" = 0 ] || fail 'concurrent child 2 did not succeed'

# Session scoping: other-session's marked same-named window is never touched.
[ "$(win_in '$2' subagents)" = @9 ] || fail 'other-session window moved'
grep -Fqx '@9 @pi-subagent-watch 1' "$tmp/tmux-state/winopts" || fail 'other-session ownership mark disturbed'
[ "$(panes_in @9)" = %8 ] || fail 'other-session panes disturbed'

# Ownership: an extra same-named window is refused outright (no guessing).
# (A window row needs a live pane row to list, as in real tmux.)
printf '@7 $1 subagents\n' >> "$tmp/tmux-state/windows"
printf '%%7 @7 %s\n' "$sup_sleep" >> "$tmp/tmux-state/panes"
printf 'Dup task.\n' > dup.md
if dup_output=$(PATH="$tmp/bin:$PATH" "$helper" start dup.md 2>"$tmp/dup.err"); then
    fail 'duplicate-name launch succeeded'
fi
grep -qi 'refusing' "$tmp/dup.err" || fail 'duplicate refusal gave no reason'
dup_id=$(value id "$dup_output")
printf '%s\n' "$dup_output" | grep -q '^watch=failed reason=tmux-setup' || fail 'failed launch reported no truthful watch=failed line'
if printf '%s\n' "$dup_output" | grep -q '^window='; then fail 'failed launch claimed a window'; fi
[ ! -d ".pi-subagent-runs/$dup_id/busy" ] || fail 'failed launch stranded its busy marker'
[ ! -e ".pi-subagent-runs/$dup_id/session.jsonl" ] || fail 'failed launch started a child'
[ ! -e ".pi-subagent-runs/$dup_id/turn-001.pid" ] || fail 'failed launch left a turn pid'
[ ! -e ".pi-subagent-runs/$dup_id/turn-001.exit-code" ] || fail 'failed launch fabricated an exit code'
PATH="$tmp/bin:$PATH" "$helper" status "$dup_id" | grep -q 'status=incomplete' || fail 'failed launch did not read back as incomplete'
grep -v '^@7 ' "$tmp/tmux-state/windows" > "$tmp/tmux-state/windows.tmp"
mv "$tmp/tmux-state/windows.tmp" "$tmp/tmux-state/windows"
grep -v '^%7 ' "$tmp/tmux-state/panes" > "$tmp/tmux-state/panes.tmp"
mv "$tmp/tmux-state/panes.tmp" "$tmp/tmux-state/panes"

# A lone legacy unmarked window is refused too: no migration, no reuse.
owned_row=$(grep " \$1 subagents$" "$tmp/tmux-state/windows" | head -n 1)
owned_id=${owned_row%% *}
grep -v "^$owned_id " "$tmp/tmux-state/windows" > "$tmp/tmux-state/windows.tmp"
mv "$tmp/tmux-state/windows.tmp" "$tmp/tmux-state/windows"
grep -v "^$owned_id " "$tmp/tmux-state/panes" > "$tmp/tmux-state/panes.tmp"
mv "$tmp/tmux-state/panes.tmp" "$tmp/tmux-state/panes"
grep -v "^$owned_id " "$tmp/tmux-state/winopts" > "$tmp/tmux-state/winopts.tmp"
mv "$tmp/tmux-state/winopts.tmp" "$tmp/tmux-state/winopts"
printf '@6 $1 subagents\n' >> "$tmp/tmux-state/windows"
printf '%%6 @6 %s\n' "$sup_sleep" >> "$tmp/tmux-state/panes"
printf 'Legacy task.\n' > legacy.md
if legacy_output=$(PATH="$tmp/bin:$PATH" "$helper" start legacy.md 2>"$tmp/legacy.err"); then
    fail 'legacy-unmarked launch succeeded'
fi
grep -qi 'legacy' "$tmp/legacy.err" || fail 'legacy refusal gave no reason'
legacy_id=$(value id "$legacy_output")
printf '%s\n' "$legacy_output" | grep -q '^watch=failed reason=tmux-setup' || fail 'legacy failure reported no truthful watch=failed line'
[ ! -d ".pi-subagent-runs/$legacy_id/busy" ] || fail 'legacy failure stranded its busy marker'
[ ! -e ".pi-subagent-runs/$legacy_id/session.jsonl" ] || fail 'legacy failure started a child'
[ "$(win_in '$1' subagents)" = @6 ] || fail 'legacy window was migrated or reused'
grep -v '^@6 ' "$tmp/tmux-state/windows" > "$tmp/tmux-state/windows.tmp"
mv "$tmp/tmux-state/windows.tmp" "$tmp/tmux-state/windows"
grep -v '^%6 ' "$tmp/tmux-state/panes" > "$tmp/tmux-state/panes.tmp"
mv "$tmp/tmux-state/panes.tmp" "$tmp/tmux-state/panes"
# The owned window is gone; later launches recreate it via the create path.

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
printf '%s\n' "$headless_output" | grep -q '^watch=none reason=not-inside-tmux$' || fail 'dead-server headless reported no explicit reason'
if printf '%s\n' "$headless_output" | grep -q '^window='; then fail 'dead-server headless claimed a window'; fi

printf 'No tmux task.\n' > notmux.md
notmux_output=$(PATH="$tmp/bin-notmux2" "$helper" start notmux.md 2>"$tmp/notmux.err")
printf '%s\n' "$notmux_output" | grep -q '^watch=none reason=tmux-not-installed$' || fail 'missing tmux reported no explicit reason'
if printf '%s\n' "$notmux_output" | grep -q '^window='; then fail 'missing-tmux headless claimed a window'; fi
grep -q 'headless' "$tmp/notmux.err" || fail 'missing tmux did not produce a notice'
[ -f ".pi-subagent-runs/$(value id "$notmux_output")/turn-001.result.md" ] || fail 'missing-tmux headless child did not publish its result'

printf 'Outside task.\n' > outside.md
outside_output=$(env -u TMUX -u TMUX_PANE PATH="$tmp/bin:$PATH" "$helper" start outside.md 2>"$tmp/outside.err")
printf '%s\n' "$outside_output" | grep -q '^watch=none reason=not-inside-tmux$' || fail 'outside-tmux headless reported no explicit reason'
if printf '%s\n' "$outside_output" | grep -q '^window='; then fail 'outside-tmux headless claimed a window'; fi
[ -f ".pi-subagent-runs/$(value id "$outside_output")/turn-001.result.md" ] || fail 'outside-tmux headless child did not publish its result'

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
grep -q 'agent=implementer' "$tmp/pi-env.log" || fail 'work did not relabel the child as the implementer agent'
[ "$(tail -n 1 "$plan_session.meta" | cut -d '|' -f 1,2)" = 'opencode-go/deepseek-v4.1-flash|max' ] || fail 'work did not default to the implementer profile'
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
grep -q 'agent=reviewer' "$tmp/pi-env.log" || fail 'critique child did not get the reviewer agent name'
[ "$(tail -n 1 "$critique_session.meta" | cut -d '|' -f 1,2)" = 'github-copilot/kimi-k3|high' ] || fail 'critique did not default to the frontier critic profile'
[ "$(grep -c 'exclude_tools=edit,write' "$tmp/pi-env.log")" = 2 ] || fail 'critic child was not restricted to read-only tools'
grep -q '^PASS' "$(value result "$critique_output")" || fail 'critic did not PASS a completed plan'

printf 'Another arc.\n' > arc-task2.md
plan2_output=$(PATH="$tmp/bin:$PATH" "$helper" plan arc-task2.md)
plan2_id=$(value id "$plan2_output")
PATH="$tmp/bin:$PATH" "$helper" work "$plan2_id" >/dev/null
critique2_output=$(PATH="$tmp/bin:$PATH" "$helper" critique "$plan2_id")
grep -q '^FIX:' "$(value result "$critique2_output")" || fail 'critic did not flag an incomplete plan'

# --- real-tmux integration: private server only, skipped if tmux is absent.
# Uses the real tmux binary with the fake pi, so children stay fast and
# deterministic. Never touches the default socket or the user's sessions:
# every tmux call here passes -L with this run's private socket name.
if command -v tmux >/dev/null 2>&1; then
    env -u TMUX -u TMUX_PANE tmux list-sessions >"$tmp/user-sessions.before" 2>&1 || :
    RL_SOCK=pi-subagent-test-$$
    tmux -L "$RL_SOCK" kill-server >/dev/null 2>&1 || :
    tmux -L "$RL_SOCK" -f /dev/null new-session -d -s rtsess -n shell sleep 300 || fail 'real-tmux setup: cannot start private server'
    tmux -L "$RL_SOCK" new-session -d -s rtother -n shell sleep 300 || fail 'real-tmux setup: cannot start second session'
    RL_SOCKPATH=$(tmux -L "$RL_SOCK" display-message -p -t rtsess '#{socket_path}') || fail 'real-tmux setup: no socket path'
    RL_PANE=$(tmux -L "$RL_SOCK" display-message -p -t rtsess '#{pane_id}') || fail 'real-tmux setup: no supervisor pane'
    mkdir "$tmp/bin-real"
    cp "$tmp/bin/pi" "$tmp/bin-real/pi"
    # Pin every pane child to the fake pi: real panes inherit the tmux
    # server's environment (user PATH included), so an unpinned `pi` could
    # resolve to a real agent there. The concurrent launches below override
    # this pin with slow-pi, which execs the same fake after a delay.
    RT_PI_WAS_SET=false
    if [ -n "${PI_SUBAGENT_PI:-}" ]; then RT_PI_WAS_SET=true; RT_SAVED_PI=$PI_SUBAGENT_PI; fi
    export PI_SUBAGENT_PI="$tmp/bin-real/pi"
    # Test-only slow pi: real panes inherit the tmux server's environment,
    # so the FAKE_PI_GATE knob cannot reach them; routing pi through this
    # wrapper (via the production PI_SUBAGENT_PI forwarding) instead holds
    # concurrent panes open deterministically.
    printf '#!/bin/sh\nsleep 10\nexec "%s/pi" "$@"\n' "$tmp/bin-real" > "$tmp/bin-real/slow-pi"
    chmod +x "$tmp/bin-real/slow-pi"
    RTPATH="$tmp/bin-real:$PATH"
    OLD_TMUX=$TMUX
    OLD_TMUX_PANE=$TMUX_PANE
    export TMUX="$RL_SOCKPATH,$$,0" TMUX_PANE="$RL_PANE"
    rt() { tmux -L "$RL_SOCK" "$@"; }

    # Sequential last-pane launch against real window deletion: rt1 finishes
    # leaving a single dead pane; rt2 must split fresh instead of hitting a
    # stale window id (no headless fallback).
    printf 'Real last-pane one.\n' > rt1.md
    rt1_output=$(PATH="$RTPATH" "$helper" start rt1.md)
    rt1_pane=$(watch_pane_of "$rt1_output" rtsess)
    [ -n "$rt1_pane" ] || fail 'real-tmux rt1 reported no watch pane'
    printf 'Real last-pane two.\n' > rt2.md
    rt2_output=$(PATH="$RTPATH" "$helper" start rt2.md)
    rt2_pane=$(watch_pane_of "$rt2_output" rtsess)
    [ -n "$rt2_pane" ] || fail 'real-tmux last-pane launch did not report its watch pane'
    [ "$rt2_pane" != "$rt1_pane" ] || fail 'real-tmux launch reused the finished pane'
    rt_win=$(rt list-windows -t rtsess -F '#{window_id} #{window_name}' | awk '$2 == "subagents" { print $1; exit }')
    [ -n "$rt_win" ] || fail 'real-tmux watch window missing after last-pane launch'
    [ "$(rt list-panes -t "$rt_win" -F '#{pane_id}' | wc -l | tr -d ' ')" = 1 ] || fail 'real-tmux last-pane launch left extra panes'
    rt list-panes -t "$rt_win" -F '#{pane_id}:#{pane_dead}' | grep -q "^$rt2_pane:1$" || fail 'real-tmux fast-exit pane was not retained'
    [ "$(rt show-options -w -t "$rt_win" @pi-subagent-watch)" = '@pi-subagent-watch 1' ] || fail 'real-tmux ownership mark missing'
    [ "$(rt show-options -w -t "$rt_win" remain-on-exit)" = 'remain-on-exit on' ] || fail 'real-tmux remain-on-exit missing'
    rt1_id=$(value id "$rt1_output")
    rt2_id=$(value id "$rt2_output")
    [ "$(cat ".pi-subagent-runs/$rt1_id/turn-001.result.md")" = 'fake response' ] || fail 'real-tmux rt1 did not publish the fake result'
    [ "$(cat ".pi-subagent-runs/$rt2_id/turn-001.result.md")" = 'fake response' ] || fail 'real-tmux rt2 did not publish the fake result'

    # Current-session targeting: the watch window lives in the supervisor's
    # session; rtother stays untouched.
    if rt list-windows -t rtother -F '#{window_name}' | grep -q '^subagents$'; then
        fail 'real-tmux launch leaked into the other session'
    fi

    # Isolated concurrent launch: both children gate on the same file, so
    # both panes are live at once on a single owned window, then both finish.
    printf 'Real concurrent one.\n' > rtc1.md
    printf 'Real concurrent two.\n' > rtc2.md
    rtc1_output=$(PI_SUBAGENT_PI="$tmp/bin-real/slow-pi" PATH="$RTPATH" "$helper" start --async rtc1.md)
    rtc1_id=$(value id "$rtc1_output")
    rtc2_output=$(PI_SUBAGENT_PI="$tmp/bin-real/slow-pi" PATH="$RTPATH" "$helper" start --async rtc2.md)
    rtc2_id=$(value id "$rtc2_output")
    for rtc_out in "$rtc1_output" "$rtc2_output"; do
        printf '%s\n' "$rtc_out" | grep -q '^watch=tmux tmux_session=rtsess window=subagents pane=%' || fail 'real-tmux concurrent launch reported no watch pane'
    done
    [ "$(rt list-panes -t "$rt_win" -F '#{pane_id}' | wc -l | tr -d ' ')" = 2 ] || fail 'real-tmux concurrent launches did not hold two panes'
    [ "$(rt list-windows -t rtsess -F '#{window_name}' | grep -c '^subagents$')" = 1 ] || fail 'real-tmux concurrent launches duplicated the window'
    PATH="$RTPATH" "$helper" wait "$rtc1_id" >/dev/null
    PATH="$RTPATH" "$helper" wait "$rtc2_id" >/dev/null
    [ "$(cat ".pi-subagent-runs/$rtc1_id/turn-001.exit-code")" = 0 ] || fail 'real-tmux concurrent child 1 failed'
    [ "$(cat ".pi-subagent-runs/$rtc2_id/turn-001.exit-code")" = 0 ] || fail 'real-tmux concurrent child 2 failed'
    [ "$(cat ".pi-subagent-runs/$rtc1_id/turn-001.result.md")" = 'fake response' ] || fail 'real-tmux concurrent child 1 published no fake result'
    [ "$(cat ".pi-subagent-runs/$rtc2_id/turn-001.result.md")" = 'fake response' ] || fail 'real-tmux concurrent child 2 published no fake result'

    # Unmarked conflict on real tmux: refused outright, diagnostics preserved.
    rt kill-window -t "$rt_win" || fail 'real-tmux setup: cannot drop owned window'
    rt new-window -d -n subagents -t rtsess: sleep 60 || fail 'real-tmux setup: cannot seed legacy window'
    printf 'Real legacy task.\n' > rtleg.md
    set +e
    rtleg_output=$(PATH="$RTPATH" "$helper" start rtleg.md 2>"$tmp/rtleg.err")
    rtleg_code=$?
    set -e
    [ "$rtleg_code" = 2 ] || fail "real-tmux legacy refusal exited $rtleg_code instead of 2"
    grep -qi 'legacy' "$tmp/rtleg.err" || fail 'real-tmux legacy refusal gave no reason'
    rtleg_id=$(value id "$rtleg_output")
    printf '%s\n' "$rtleg_output" | grep -q '^watch=failed reason=tmux-setup' || fail 'real-tmux failure reported no watch=failed line'
    if printf '%s\n' "$rtleg_output" | grep -q '^window='; then fail 'real-tmux failure claimed a window'; fi
    [ ! -d ".pi-subagent-runs/$rtleg_id/busy" ] || fail 'real-tmux failure stranded busy'
    [ ! -e ".pi-subagent-runs/$rtleg_id/session.jsonl" ] || fail 'real-tmux failure started a child'
    PATH="$RTPATH" "$helper" status "$rtleg_id" | grep -q 'status=incomplete' || fail 'real-tmux failure did not read back as incomplete'
    rt kill-window -t subagents || fail 'real-tmux cleanup: cannot drop legacy window'

    export TMUX="$OLD_TMUX" TMUX_PANE="$OLD_TMUX_PANE"
    if $RT_PI_WAS_SET; then export PI_SUBAGENT_PI="$RT_SAVED_PI"; else unset PI_SUBAGENT_PI; fi
    tmux -L "$RL_SOCK" kill-server >/dev/null 2>&1 || :
    RL_SOCK=
    env -u TMUX -u TMUX_PANE tmux list-sessions >"$tmp/user-sessions.after" 2>&1 || :
    diff "$tmp/user-sessions.before" "$tmp/user-sessions.after" >/dev/null || fail 'real-tmux section mutated the user server sessions'
else
    printf 'skip: tmux not installed; real-tmux section omitted\n'
fi

# --- herdr spawn: fake CLI only, never the live server ---
command -v python3 >/dev/null 2>&1 || fail 'herdr tests need python3'
mkdir "$tmp/bin-herdr" "$tmp/herdr-state"
: > "$tmp/herdr.log"
printf 'w1:p1 w1:t1 w1\n' > "$tmp/herdr-state/caller"
printf 'w2:p1 w2:t1 w2\n' > "$tmp/herdr-state/focused"
printf 'w1:t1 w1 editor\n' > "$tmp/herdr-state/tabs"
printf 'w2:t1 w2 writer\n' >> "$tmp/herdr-state/tabs"
printf 'w1:p1 w1:t1 w1\n' > "$tmp/herdr-state/panes"
printf 'w2:p1 w2:t1 w2\n' >> "$tmp/herdr-state/panes"
printf '2\n' > "$tmp/herdr-state/next-tab"
printf '2\n' > "$tmp/herdr-state/next-pane"
: > "$tmp/herdr-state/runs"

cat > "$tmp/bin-herdr/herdr" <<'FAKE_HERDR'
#!/bin/sh
set -eu
state=${FAKE_HERDR_STATE:?}
log=${FAKE_HERDR_LOG:?}
printf '%s\n' "$*" >> "$log"

die() {
    printf 'fake herdr: %s\n' "$*" >&2
    exit 1
}

json_list() {
    python3 -c '
import json, sys
ws, path, kind = sys.argv[1], sys.argv[2], sys.argv[3]
items = []
with open(path) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        if kind == "tabs":
            tid, w, label = line.split(" ", 2)
            if w == ws:
                items.append({"tab_id": tid, "workspace_id": w, "label": label})
        else:
            pid, tid, w = line.split()
            if w == ws:
                items.append({"pane_id": pid, "tab_id": tid, "workspace_id": w})
if kind == "tabs":
    print(json.dumps({"id": "cli:tab:list", "result": {"tabs": items, "type": "tab_list"}}))
else:
    print(json.dumps({"id": "cli:pane:list", "result": {"panes": items, "type": "pane_list"}}))
' "$1" "$2" "$3"
}

next_id() {
    n=$(cat "$state/next-$1")
    printf '%s\n' "$((n + 1))" > "$state/next-$1"
    printf '%s\n' "$n"
}

[ "$#" -ge 2 ] || die "usage: herdr GROUP CMD ..."
group=$1
cmd=$2
shift 2
case "$group $cmd" in
    "pane current")
        use_current=false
        while [ "$#" -gt 0 ]; do
            case $1 in
                --current) use_current=true; shift ;;
                *) shift ;;
            esac
        done
        if [ "$use_current" = true ]; then
            read -r pane tab ws < "$state/caller"
        else
            read -r pane tab ws < "$state/focused"
        fi
        printf '{"id":"cli:pane:current","result":{"pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"%s"},"type":"pane_current"}}\n' "$pane" "$tab" "$ws"
        ;;
    "tab list")
        workspace=
        while [ "$#" -gt 0 ]; do
            case $1 in
                --workspace) workspace=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        [ -n "$workspace" ] || die "tab list missing --workspace"
        json_list "$workspace" "$state/tabs" tabs
        ;;
    "tab create")
        workspace=; label=; cwd=; no_focus=false
        while [ "$#" -gt 0 ]; do
            case $1 in
                --workspace) workspace=$2; shift 2 ;;
                --label) label=$2; shift 2 ;;
                --cwd) cwd=$2; shift 2 ;;
                --no-focus) no_focus=true; shift ;;
                --focus) die "tab create used --focus" ;;
                --env) shift 2 ;;
                *) die "tab create bad arg $1" ;;
            esac
        done
        [ "$no_focus" = true ] || die "tab create missing --no-focus"
        [ -n "$cwd" ] || die "tab create missing --cwd"
        [ -n "$workspace" ] || die "tab create missing --workspace"
        [ "$label" = subagents ] || die "tab create label not subagents"
        tn=$(next_id tab)
        pn=$(next_id pane)
        tab_id=$workspace:t$tn
        pane_id=$workspace:p$pn
        printf '%s %s %s\n' "$tab_id" "$workspace" "$label" >> "$state/tabs"
        printf '%s %s %s\n' "$pane_id" "$tab_id" "$workspace" >> "$state/panes"
        printf '%s\n' "$cwd" > "$state/last-cwd"
        printf '{"id":"cli:tab:create","result":{"tab":{"tab_id":"%s","workspace_id":"%s","label":"%s"},"root_pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"%s"},"type":"tab_create"}}\n' \
            "$tab_id" "$workspace" "$label" "$pane_id" "$tab_id" "$workspace"
        ;;
    "pane list")
        workspace=
        while [ "$#" -gt 0 ]; do
            case $1 in
                --workspace) workspace=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        [ -n "$workspace" ] || die "pane list missing --workspace"
        json_list "$workspace" "$state/panes" panes
        ;;
    "pane split")
        pane_id=; direction=; cwd=; no_focus=false; used_current=false
        while [ "$#" -gt 0 ]; do
            case $1 in
                --current) used_current=true; shift ;;
                --direction) direction=$2; shift 2 ;;
                --cwd) cwd=$2; shift 2 ;;
                --no-focus) no_focus=true; shift ;;
                --focus) die "pane split used --focus" ;;
                --pane) pane_id=$2; shift 2 ;;
                --env|--ratio) shift 2 ;;
                --*) die "pane split bad flag $1" ;;
                *) pane_id=$1; shift ;;
            esac
        done
        [ "$used_current" = false ] || die "pane split used --current"
        [ "$direction" = down ] || die "pane split missing --direction down"
        [ "$no_focus" = true ] || die "pane split missing --no-focus"
        [ -n "$cwd" ] || die "pane split missing --cwd"
        [ -n "$pane_id" ] || die "pane split missing pane"
        tab_id=
        ws=
        while read -r pid tid wsid; do
            if [ "$pid" = "$pane_id" ]; then
                tab_id=$tid
                ws=$wsid
                break
            fi
        done < "$state/panes"
        [ -n "$tab_id" ] || die "pane split unknown pane $pane_id"
        pn=$(next_id pane)
        new_pane=$ws:p$pn
        printf '%s %s %s\n' "$new_pane" "$tab_id" "$ws" >> "$state/panes"
        printf '%s\n' "$cwd" > "$state/last-cwd"
        printf '{"id":"cli:pane:split","result":{"pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"%s"},"type":"pane_split"}}\n' \
            "$new_pane" "$tab_id" "$ws"
        ;;
    "pane run")
        [ "$#" -ge 2 ] || die "pane run needs pane and command"
        shift
        run_cmd=$*
        printf '%s\n' "$run_cmd" >> "$state/runs"
        if [ "${FAKE_HERDR_PANE_RUN:-}" = bg ]; then
            # Real pane run returns after sending Enter; delay so foreground
            # poll starts before the inner helper publishes a pid. The inner
            # exit status is not pane-run's status.
            ( sleep 1; sh -c "$run_cmd" >"$state/pane-out" 2>&1 || : ) </dev/null >/dev/null 2>&1 &
        else
            sh -c "$run_cmd" >"$state/pane-out" 2>&1 || :
        fi
        ;;
    "pane process-info")
        pane_id=
        while [ "$#" -gt 0 ]; do
            case $1 in
                --pane) pane_id=$2; shift 2 ;;
                --current) shift ;;
                *) pane_id=$1; shift ;;
            esac
        done
        case ${FAKE_HERDR_PROCESS_INFO:-} in
            fail) die "process-info failed" ;;
            omit)
                printf '{"id":"cli:pane:process_info","result":{"process_info":{"pane_id":"%s"},"type":"pane_process_info"}}\n' "$pane_id"
                ;;
            *)
                printf '{"id":"cli:pane:process_info","result":{"process_info":{"shell_pid":%s,"pane_id":"%s"},"type":"pane_process_info"}}\n' "$$" "$pane_id"
                ;;
        esac
        ;;
    "pane close")
        [ "$#" -ge 1 ] || die "pane close needs pane"
        pane_id=$1
        if [ "${FAKE_HERDR_CLOSE:-}" = fail ]; then
            die "pane close failed"
        fi
        found=false
        tab_id=
        while read -r pid tid wsid; do
            if [ "$pid" = "$pane_id" ]; then
                found=true
                tab_id=$tid
                break
            fi
        done < "$state/panes"
        [ "$found" = true ] || die "pane close unknown pane $pane_id"
        awk -v id="$pane_id" '$1 != id' "$state/panes" > "$state/panes.tmp"
        mv "$state/panes.tmp" "$state/panes"
        printf '%s\n' "$pane_id" >> "$state/closes"
        # Last pane in a tab may take the tab with it; sequential launches
        # then recreate the unique subagents tab instead of splitting.
        if [ -n "$tab_id" ] && ! awk -v t="$tab_id" '$2 == t { found=1 } END { exit !found }' "$state/panes"; then
            awk -v t="$tab_id" '$1 != t' "$state/tabs" > "$state/tabs.tmp"
            mv "$state/tabs.tmp" "$state/tabs"
        fi
        printf '{"id":"cli:pane:close","result":{"type":"pane_close"}}\n'
        ;;
    *)
        die "unsupported command: $group $cmd"
        ;;
esac
FAKE_HERDR
chmod +x "$tmp/bin-herdr/herdr"

export HERDR_ENV=1
unset PI_SUBAGENT_HERDR_INNER
export FAKE_HERDR_STATE=$tmp/herdr-state
export FAKE_HERDR_LOG=$tmp/herdr.log
HPATH="$tmp/bin-herdr:$tmp/bin:$PATH"
work_pwd=$(pwd -P)

herdr_pane_of() {
    printf '%s\n' "$1" | sed -n 's/^watch=herdr workspace=[^ ]* tab=[^ ]* pane=//p'
}

assert_herdr_closed_after_run() {
    pane=$1
    awk -v p="$pane" '
        $1 == "pane" && $2 == "run" && $3 == p { run_at = NR }
        $1 == "pane" && $2 == "close" && $3 == p { close_at = NR }
        END { exit !(run_at && close_at && run_at < close_at) }
    ' "$tmp/herdr.log" || fail "herdr pane $pane was not closed after pane run"
    grep -Fqx "$pane" "$tmp/herdr-state/closes" || fail "herdr pane $pane was not recorded as closed"
}

# pane-run lines shell-quote the launcher path; strip one level of quoting
# for path/content assertions (test tmp paths contain no embedded quotes).
dequote() {
    case $1 in
        \'*\') printf '%s' "$1" | sed "s/^'//; s/'\$//; s/'\\\\''/'/g" ;;
        *) printf '%s' "$1" ;;
    esac
}

# The herdr watch command is typed as a short launcher path (long typed
# commands get mangled on Linux herdr). Resolve a recorded pane-run line to
# the real command text so content assertions check what actually executes.
resolve_run() {
    line=$(dequote "$1")
    if [ -f "$line" ]; then
        cat "$line"
    else
        printf '%s\n' "$line"
    fi
}

# Missing herdr binary: fail hard, no tmux/headless fallback.
printf 'Herdr missing binary.\n' > herdr-missing.md
set +e
missing_output=$(PATH="$tmp/bin:/usr/bin:/bin" "$helper" start herdr-missing.md 2>"$tmp/herdr-missing.err")
missing_code=$?
set -e
[ "$missing_code" = 2 ] || fail "missing herdr exited $missing_code instead of 2"
grep -q 'herdr not found' "$tmp/herdr-missing.err" || fail 'missing herdr gave no reason'
grep -q 'not falling back' "$tmp/herdr-missing.err" || fail 'missing herdr did not refuse fallback'
if printf '%s\n' "$missing_output" | grep -q '^watch=tmux'; then fail 'missing herdr fell back to tmux'; fi
if printf '%s\n' "$missing_output" | grep -q '^watch=none'; then fail 'missing herdr fell back to headless'; fi

# First launch creates the workspace subagents tab (caller pane, not focused).
printf 'Herdr first.\n' > herdr1.md
h1_output=$(PATH="$HPATH" "$helper" start --async herdr1.md)
h1_id=$(value id "$h1_output")
[ -n "$h1_id" ] || fail 'herdr first start did not return an id'
printf '%s\n' "$h1_output" | grep -q '^watch=herdr workspace=w1 tab=w1:t2 pane=w1:p2$' || fail 'herdr first start reported no watch=herdr line'
[ "$(cat ".pi-subagent-runs/$h1_id/orchestrator-target")" = subagent-chat-abcdef1234567890 ] || fail 'herdr first start did not persist the derived orchestrator target'
[ "$(awk -F= 'BEGIN { t = "" } $1 == "target" { t = $2 } END { print t }' "$tmp/pi-env.log")" = subagent-chat-abcdef1234567890 ] || fail 'herdr inner did not receive the derived orchestrator target'
[ "$(cat ".pi-subagent-runs/$h1_id/turn-001.result.md")" = 'fake response' ] || fail 'herdr first inner TUI did not publish a result'
[ "$(cat "$tmp/herdr-state/last-cwd")" = "$work_pwd" ] || fail 'herdr tab create cwd was not pwd -P'
grep -q 'tab create --workspace w1 --label subagents --cwd ' "$tmp/herdr.log" || fail 'herdr first start did not create the subagents tab'
grep -q -- '--no-focus' "$tmp/herdr.log" || fail 'herdr tab create omitted --no-focus'
grep -q '^pane current --current$' "$tmp/herdr.log" || fail 'herdr did not call pane current --current'
if grep -q -- '--workspace w2' "$tmp/herdr.log"; then fail 'herdr used the focused workspace instead of the caller'; fi
if grep -q '^pane split ' "$tmp/herdr.log"; then fail 'herdr first start split instead of creating the tab'; fi
grep -q '^pane run w1:p2 ' "$tmp/herdr.log" || fail 'herdr first start did not pane-run the root pane'
h1_raw=$(head -n 1 "$tmp/herdr-state/runs")
h1_path=$(dequote "$h1_raw")
[ "${#h1_raw}" -le 130 ] || fail "herdr pane-run typed ${#h1_raw} chars instead of a short launcher path"
case $h1_raw in
    \'*\') : ;;
    *) fail 'herdr pane-run typed the launcher path unquoted' ;;
esac
case $h1_path in
    */.pi-subagent-runs/*/.launch-*.sh) : ;;
    *) fail 'herdr pane-run did not type the launcher path' ;;
esac
[ -x "$h1_path" ] || fail 'herdr launcher script is not executable'
h1_run=$(resolve_run "$h1_raw")
printf '%s\n' "$h1_run" | grep -q '__run' || fail 'herdr pane run did not invoke inner __run'
printf '%s\n' "$h1_run" | grep -q 'PI_SUBAGENT_HERDR_INNER=1' || fail 'herdr pane run omitted the inner marker'
if printf '%s\n' "$h1_run" | grep -q -- '--async'; then fail 'herdr inner command included --async'; fi
if printf '%s\n' "$h1_run" | grep -q ' start '; then fail 'herdr pane-ran start instead of __run'; fi
printf '%s\n' "$h1_run" | grep -q -- '-u PI_SESSION_ID' || fail 'herdr inner command did not unset PI_SESSION_ID'
printf '%s\n' "$h1_run" | grep -q ' pane$' || fail 'herdr inner command was not pane mode'
printf '%s\n' "$h1_run" | grep -q "PI_SUBAGENT_HERDR_PANE='w1:p2'" || fail 'herdr inner command omitted the allocated pane id'
grep -q '^herdr_inner=1$' "$tmp/pi-env.log" || fail 'herdr inner Pi lost PI_SUBAGENT_HERDR_INNER'
if grep -q '^herdr_pane=w1:p2$' "$tmp/pi-env.log"; then fail 'PI_SUBAGENT_HERDR_PANE leaked into Pi'; fi
assert_herdr_closed_after_run w1:p2
if awk -v p='w1:p2' '$1 == p { found=1 } END { exit !found }' "$tmp/herdr-state/panes"; then fail 'herdr first watch pane remained after the turn'; fi

# Sequential after the previous pane closed: Herdr may drop the empty
# subagents tab, so the next launch recreates it (unique label, no split).
printf 'Herdr second.\n' > herdr2.md
h2_output=$(PATH="$HPATH" "$helper" start --orchestrator-target named-supervisor herdr2.md)
h2_id=$(value id "$h2_output")
[ -n "$h2_id" ] || fail 'herdr second start did not return an id'
printf '%s\n' "$h2_output" | grep -q '^watch=herdr workspace=w1 tab=w1:t3 pane=w1:p3$' || fail 'herdr second start did not recreate the subagents tab after the previous pane closed'
[ "$(cat ".pi-subagent-runs/$h2_id/orchestrator-target")" = named-supervisor ] || fail 'herdr second start did not persist the verbatim orchestrator target'
[ "$(awk -F= 'BEGIN { t = "" } $1 == "target" { t = $2 } END { print t }' "$tmp/pi-env.log")" = named-supervisor ] || fail 'herdr inner did not receive the verbatim orchestrator target'
[ "$(grep -c '^tab create ' "$tmp/herdr.log")" = 2 ] || fail 'herdr second start did not recreate the subagents tab'
if grep -q '^pane split ' "$tmp/herdr.log"; then fail 'herdr sequential second split instead of recreating the tab'; fi
[ "$(cat "$tmp/herdr-state/last-cwd")" = "$work_pwd" ] || fail 'herdr tab recreate cwd was not pwd -P'
h2_run=$(resolve_run "$(tail -n 1 "$tmp/herdr-state/runs")")
printf '%s\n' "$h2_run" | grep -q '__run' || fail 'herdr second pane run did not invoke inner __run'
if printf '%s\n' "$h2_run" | grep -q -- '--async'; then fail 'herdr second inner command included --async'; fi
printf '%s\n' "$h2_run" | grep -q "PI_SUBAGENT_HERDR_PANE='w1:p3'" || fail 'herdr second inner command omitted the allocated pane id'
assert_herdr_closed_after_run w1:p3

# Foreground launch must not fabricate 143 when process-info fails and the
# inner helper has not published a pid yet (real pane run is non-blocking).
printf 'Herdr no shell_pid.\n' > herdr-nospid.md
set +e
nospid_output=$(FAKE_HERDR_PANE_RUN=bg FAKE_HERDR_PROCESS_INFO=fail PATH="$HPATH" "$helper" start herdr-nospid.md)
nospid_code=$?
set -e
[ "$nospid_code" = 0 ] || fail "foreground herdr with no shell_pid exited $nospid_code instead of 0"
nospid_id=$(value id "$nospid_output")
[ -n "$nospid_id" ] || fail 'foreground herdr with no shell_pid returned no id'
[ "$(cat ".pi-subagent-runs/$nospid_id/turn-001.exit-code")" != 143 ] || fail 'foreground herdr fabricated exit 143 when process-info failed'
[ "$(cat ".pi-subagent-runs/$nospid_id/turn-001.result.md")" = 'fake response' ] || fail 'foreground herdr with no shell_pid did not publish a result'
printf '%s\n' "$nospid_output" | grep -q '^watch=herdr ' || fail 'foreground herdr with no shell_pid reported no watch=herdr line'

# Same empty-pid path when process-info omits shell_pid.
printf 'Herdr omit shell_pid.\n' > herdr-omit.md
set +e
omit_output=$(FAKE_HERDR_PANE_RUN=bg FAKE_HERDR_PROCESS_INFO=omit PATH="$HPATH" "$helper" start herdr-omit.md)
omit_code=$?
set -e
[ "$omit_code" = 0 ] || fail "foreground herdr with omitted shell_pid exited $omit_code instead of 0"
omit_id=$(value id "$omit_output")
[ "$(cat ".pi-subagent-runs/$omit_id/turn-001.exit-code")" != 143 ] || fail 'foreground herdr fabricated exit 143 when process-info omitted shell_pid'
[ "$(cat ".pi-subagent-runs/$omit_id/turn-001.result.md")" = 'fake response' ] || fail 'foreground herdr with omitted shell_pid did not publish a result'

# status / wait / list / stop stay local: they must not call herdr.
herdr_lines=$(wc -l < "$tmp/herdr.log" | tr -d ' ')
PATH="$HPATH" "$helper" status "$h1_id" | grep -q 'status=succeeded' || fail 'herdr status did not report success'
PATH="$HPATH" "$helper" wait "$h1_id" >/dev/null || fail 'herdr wait failed on a finished turn'
PATH="$HPATH" "$helper" list | grep -q "id=$h1_id .*status=succeeded" || fail 'herdr list missed the herdr-started session'
PATH="$HPATH" "$helper" stop "$h1_id" >/dev/null || fail 'herdr stop failed on a finished session'
herdr_lines_after=$(wc -l < "$tmp/herdr.log" | tr -d ' ')
[ "$herdr_lines" = "$herdr_lines_after" ] || fail 'status/wait/list/stop invoked herdr'

# Local commands with leaked inner env must not close a parent watch pane.
printf 'w1:t90 w1 legacy-local\n' >> "$tmp/herdr-state/tabs"
printf 'w1:p90 w1:t90 w1\n' >> "$tmp/herdr-state/panes"
legacy_close_before=$(grep -c '^pane close w1:p90$' "$tmp/herdr.log" || true)
PI_SUBAGENT_HERDR_INNER=1 PI_SUBAGENT_HERDR_PANE=w1:p90 PATH="$HPATH" "$helper" status "$h1_id" | grep -q 'status=succeeded' || fail 'legacy-env status did not report success'
PI_SUBAGENT_HERDR_INNER=1 PI_SUBAGENT_HERDR_PANE=w1:p90 PATH="$HPATH" "$helper" wait "$h1_id" >/dev/null || fail 'legacy-env wait failed on a finished turn'
PI_SUBAGENT_HERDR_INNER=1 PI_SUBAGENT_HERDR_PANE=w1:p90 PATH="$HPATH" "$helper" list | grep -q "id=$h1_id .*status=succeeded" || fail 'legacy-env list missed the session'
PI_SUBAGENT_HERDR_INNER=1 PI_SUBAGENT_HERDR_PANE=w1:p90 PATH="$HPATH" "$helper" stop "$h1_id" >/dev/null || fail 'legacy-env stop failed on a finished session'
legacy_close_after=$(grep -c '^pane close w1:p90$' "$tmp/herdr.log" || true)
[ "$legacy_close_before" = "$legacy_close_after" ] || fail 'legacy-env status/list/wait/stop called herdr pane close'
if awk -v p='w1:p90' '$1 == p { found=1 } END { exit !found }' "$tmp/herdr-state/panes"; then :; else fail 'legacy-env local commands closed the inherited parent pane'; fi

# Failing inner turn still closes its pane and keeps the real status.
printf 'FAIL this herdr task.\n' > herdr-fail.md
set +e
hf_output=$(PATH="$HPATH" "$helper" start herdr-fail.md)
hf_code=$?
set -e
[ "$hf_code" = 7 ] || fail "foreground herdr failure exited $hf_code instead of 7"
hf_id=$(value id "$hf_output")
hf_pane=$(herdr_pane_of "$hf_output")
[ -n "$hf_pane" ] || fail 'foreground herdr failure reported no watch pane'
hf_result=$(value result "$hf_output")
hf_partial=${hf_result%.md}.partial.md
[ ! -e "$hf_result" ] || fail 'failing herdr turn published a result artifact'
[ "$(cat "$hf_partial")" = 'partial response' ] || fail 'failing herdr turn partial output was not preserved'
[ "$(cat ".pi-subagent-runs/$hf_id/turn-001.exit-code")" = 7 ] || fail 'failing herdr turn exit code was not preserved'
assert_herdr_closed_after_run "$hf_pane"

# Concurrent turns split while both panes are live, then each closes only its own.
printf 'Herdr concurrent one.\n' > herdr-c1.md
printf 'Herdr concurrent two.\n' > herdr-c2.md
rm -f "$tmp/hgate"
hc1_output=$(FAKE_HERDR_PANE_RUN=bg FAKE_PI_GATE="$tmp/hgate" PATH="$HPATH" "$helper" start --async herdr-c1.md)
hc1_id=$(value id "$hc1_output")
hc1_pane=$(herdr_pane_of "$hc1_output")
[ -n "$hc1_pane" ] || fail 'herdr concurrent 1 reported no watch pane'
awk -v p="$hc1_pane" '$1 == p { found=1 } END { exit !found }' "$tmp/herdr-state/panes" || fail "herdr concurrent 1 pane $hc1_pane gone before concurrent 2"
hc2_output=$(FAKE_HERDR_PANE_RUN=bg FAKE_PI_GATE="$tmp/hgate" PATH="$HPATH" "$helper" start --async herdr-c2.md)
hc2_id=$(value id "$hc2_output")
hc2_pane=$(herdr_pane_of "$hc2_output")
[ -n "$hc2_pane" ] || fail 'herdr concurrent 2 reported no watch pane'
[ "$hc1_pane" != "$hc2_pane" ] || fail 'herdr concurrent turns reused a pane'
grep -q "^pane split $hc1_pane --direction down --no-focus --cwd " "$tmp/herdr.log" || fail 'herdr concurrent 2 did not split the live subagents pane'
if grep '^pane split ' "$tmp/herdr.log" | grep -q -- '--current'; then fail 'herdr concurrent split used --current'; fi
if grep '^pane split ' "$tmp/herdr.log" | grep -q 'w1:p1 '; then fail 'herdr concurrent split the supervisor pane'; fi
if grep '^pane split ' "$tmp/herdr.log" | grep -q 'w2:p1 '; then fail 'herdr concurrent split the focused pane'; fi
awk -v a="$hc1_pane" -v b="$hc2_pane" '$1 == a { aa=1 } $1 == b { bb=1 } END { exit !(aa && bb) }' "$tmp/herdr-state/panes" || fail 'herdr concurrent turns did not keep both watch panes live'
: > "$tmp/hgate"
PATH="$HPATH" "$helper" wait "$hc1_id" >/dev/null
PATH="$HPATH" "$helper" wait "$hc2_id" >/dev/null
wait_for_grep "$tmp/herdr.log" "^pane close $hc1_pane$" || fail 'herdr concurrent 1 never closed its pane'
wait_for_grep "$tmp/herdr.log" "^pane close $hc2_pane$" || fail 'herdr concurrent 2 never closed its pane'
assert_herdr_closed_after_run "$hc1_pane"
assert_herdr_closed_after_run "$hc2_pane"
[ "$(cat ".pi-subagent-runs/$hc1_id/turn-001.exit-code")" = 0 ] || fail 'herdr concurrent 1 did not succeed'
[ "$(cat ".pi-subagent-runs/$hc2_id/turn-001.exit-code")" = 0 ] || fail 'herdr concurrent 2 did not succeed'
if awk -v p='w1:p1' '$1 == p { found=1 } END { exit !found }' "$tmp/herdr-state/panes"; then :; else fail 'herdr concurrent close removed the supervisor pane'; fi
if awk -v p='w2:p1' '$1 == p { found=1 } END { exit !found }' "$tmp/herdr-state/panes"; then :; else fail 'herdr concurrent close removed the focused pane'; fi

# Pane-close failure after finalize must not overwrite the turn result.
printf 'Herdr close fail.\n' > herdr-closefail.md
set +e
hcf_output=$(FAKE_HERDR_CLOSE=fail PATH="$HPATH" "$helper" start herdr-closefail.md)
hcf_code=$?
set -e
[ "$hcf_code" = 0 ] || fail "herdr close failure exited $hcf_code instead of the turn status 0"
hcf_id=$(value id "$hcf_output")
hcf_pane=$(herdr_pane_of "$hcf_output")
[ -n "$hcf_pane" ] || fail 'herdr close-failure start reported no watch pane'
[ "$(cat ".pi-subagent-runs/$hcf_id/turn-001.result.md")" = 'fake response' ] || fail 'herdr close failure overwrote or dropped the result'
[ "$(cat ".pi-subagent-runs/$hcf_id/turn-001.exit-code")" = 0 ] || fail 'herdr close failure overwrote the exit code'
grep -q "^pane close $hcf_pane$" "$tmp/herdr.log" || fail 'herdr close failure did not attempt pane close'
if grep -Fqx "$hcf_pane" "$tmp/herdr-state/closes" 2>/dev/null; then fail 'failed pane close was recorded as closed'; fi

# Nested helper spawned from inside the Herdr Pi must not close the parent pane.
printf 'NESTED-HELPER parent.\n' > herdr-nested.md
np_output=$(FAKE_NESTED_HELPER="$helper" FAKE_NESTED_PROMPT="$tmp/nested-child.md" FAKE_NESTED_OUT="$tmp/nested.out" FAKE_NESTED_ERR="$tmp/nested.err" PATH="$HPATH" "$helper" start herdr-nested.md)
np_id=$(value id "$np_output")
np_pane=$(herdr_pane_of "$np_output")
[ -n "$np_pane" ] || fail 'herdr nested parent reported no watch pane'
np_closes=$(grep -c "^pane close $np_pane$" "$tmp/herdr.log" || true)
[ "$np_closes" = 1 ] || fail "herdr nested grandchild closed the parent pane or parent did not close once (closes=$np_closes)"
assert_herdr_closed_after_run "$np_pane"
[ "$(cat ".pi-subagent-runs/$np_id/turn-001.result.md")" = 'fake response' ] || fail 'herdr nested parent did not publish a result'
grep -q '^watch=none' "$tmp/nested.out" || fail 'herdr nested grandchild did not run headless'
if grep -q '^watch=herdr' "$tmp/nested.out"; then fail 'herdr nested grandchild re-entered herdr launch'; fi
[ "$(awk '/^herdr_pane=/ { v = $0 } END { print v }' "$tmp/pi-env.log")" = 'herdr_pane=' ] || fail 'Pi still saw PI_SUBAGENT_HERDR_PANE'

# Early die after allocate (corrupt profile) still closes the pane and keeps status 2.
printf 'w1:t80 w1 corrupt-profile\n' >> "$tmp/herdr-state/tabs"
printf 'w1:p80 w1:t80 w1\n' >> "$tmp/herdr-state/panes"
corrupt_dir=.pi-subagent-runs/task.corruptpane
mkdir -p "$corrupt_dir/busy"
printf 'bad\n' > "$corrupt_dir/profile"
printf 'implementer\n' > "$corrupt_dir/agent"
: > "$corrupt_dir/turn-001.prompt.md"
: > "$corrupt_dir/turn-001.skills"
set +e
env -u TMUX -u TMUX_PANE HERDR_ENV=1 PI_SUBAGENT_HERDR_INNER=1 PI_SUBAGENT_HERDR_PANE=w1:p80 PATH="$HPATH" \
    "$helper" __run "$corrupt_dir" 001 pane 2>"$tmp/corrupt.err"
corrupt_code=$?
set -e
[ "$corrupt_code" = 2 ] || fail "corrupt-profile inner exited $corrupt_code instead of 2"
grep -q 'invalid model profile' "$tmp/corrupt.err" || fail 'corrupt-profile inner gave no profile error'
grep -q '^pane close w1:p80$' "$tmp/herdr.log" || fail 'corrupt-profile inner did not close its allocated pane'
grep -Fqx w1:p80 "$tmp/herdr-state/closes" || fail 'corrupt-profile pane was not recorded as closed'
if awk -v p='w1:p80' '$1 == p { found=1 } END { exit !found }' "$tmp/herdr-state/panes"; then fail 'corrupt-profile pane remained after die'; fi
[ ! -e "$corrupt_dir/turn-001.exit-code" ] || fail 'corrupt-profile inner fabricated an exit-code artifact'
[ ! -e "$corrupt_dir/turn-001.result.md" ] || fail 'corrupt-profile inner published a result'

# Duplicate subagents labels are refused; no child, no fallback.
# Seed two labels: prior turns closed their last pane, which may drop the tab.
printf 'w1:t98 w1 subagents\n' >> "$tmp/herdr-state/tabs"
printf 'w1:t99 w1 subagents\n' >> "$tmp/herdr-state/tabs"
printf 'Herdr duplicate.\n' > herdr-dup.md
set +e
dup_output=$(PATH="$HPATH" "$helper" start herdr-dup.md 2>"$tmp/herdr-dup.err")
dup_code=$?
set -e
[ "$dup_code" = 2 ] || fail "duplicate subagents tabs exited $dup_code instead of 2"
grep -qi 'duplicate' "$tmp/herdr-dup.err" || fail 'duplicate subagents tabs gave no reason'
dup_id=$(value id "$dup_output")
[ ! -e ".pi-subagent-runs/$dup_id/session.jsonl" ] || fail 'duplicate tab refusal started a child'
[ ! -d ".pi-subagent-runs/$dup_id/busy" ] || fail 'duplicate tab refusal stranded busy'
if printf '%s\n' "$dup_output" | grep -q '^watch=tmux'; then fail 'duplicate tab refusal fell back to tmux'; fi
if printf '%s\n' "$dup_output" | grep -q '^watch=none'; then fail 'duplicate tab refusal fell back to headless'; fi

unset HERDR_ENV

printf 'ok\n'

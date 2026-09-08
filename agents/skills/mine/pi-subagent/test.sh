#!/bin/sh
set -eu

skill_dir=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)
helper=$skill_dir/scripts/pi-subagent.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pi-subagent-test.XXXXXX")
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
[ "$(cut -d '|' -f 1,2 "$session.meta" | head -n 1)" = 'opencode/muse-spark-1.3-contributor-free|xhigh' ] || fail 'default model profile was not used'
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
[ "$(tail -n 1 "$plan_session.meta" | cut -d '|' -f 1,2)" = 'opencode/muse-spark-1.3-contributor-free|xhigh' ] || fail 'work did not default to the implementer profile'
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
[ "$(tail -n 1 "$critique_session.meta" | cut -d '|' -f 1,2)" = 'github-copilot/grok-4.6|xhigh' ] || fail 'critique did not default to the frontier critic profile'
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

printf 'ok\n'

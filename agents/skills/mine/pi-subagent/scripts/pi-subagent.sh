#!/bin/sh
set -u
umask 077

DEFAULT_MODEL=github-copilot/gpt-5.6-luna
DEFAULT_EFFORT=max
DEFAULT_AGENT=worker
PLANNER_MODEL=github-copilot/grok-4.6
PLANNER_EFFORT=xhigh
CRITIC_MODEL=$PLANNER_MODEL
CRITIC_EFFORT=$PLANNER_EFFORT
WATCH_WINDOW=subagents
SUPERVISOR_BLOCK='If you have the contact_supervisor tool, keep the supervisor informed through it:
- Blocked, need approval, or facing a scope/API/product fork: contact_supervisor({ reason: "need_decision", message: "<question>" }) - continue only after the reply arrives.
- A discovery that changes the plan: contact_supervisor({ reason: "progress_update", message: "UPDATE: <summary>" }).
- Before your final response, always send a completion report: contact_supervisor({ reason: "progress_update", message: "TASK COMPLETE: <outcome done/blocked/partial>; <what changed or was found>; <key files>; <what remains and suggested next step>" }).
- Do not contact the supervisor for routine narration. Decide minor ambiguities yourself and note them in the completion report.
If you do not have the contact_supervisor tool, return a self-contained final response covering the same points.'
BOUNDARY='Execute the assigned task directly. Do not spawn further agents.

'"$SUPERVISOR_BLOCK"
PLAN_STAGE='You are the PLANNER stage of a delegated work arc. Explore the codebase as needed (read-only) and turn the task below into an explicit plan. Do not edit files or implement anything. Do not spawn further agents.

Write the plan to exactly this path: %RUN_DIR%/plan.md

Format, one node per line, in execution order:

# Plan
- [ ] 1. <action> - done when <acceptance criterion>
- [ ] 2. ...

3-10 nodes, each independently checkable; note dependencies inline. When the plan file is written, reply with the node count and one line of context.'
WORK_STAGE='You are the WORKER stage of a delegated work arc. The plan is at %RUN_DIR%/plan.md - read it first.

Implement the next unchecked node (- [ ]). You may also take subsequent nodes in this same turn, but only when they are trivially small and strictly sequential. Keep focus: one node at a time.

When a node is complete, tick it in plan.md (- [x]) and stop. If a node is blocked or the plan turns out to be wrong, escalate with contact_supervisor reason "need_decision" instead of guessing. Do not spawn further agents.'
CRITIQUE_STAGE='You are the CRITIC stage of a delegated work arc: a fresh, skeptical review of work another session finished. Read-only; do not edit files. Do not spawn further agents.

The task below names the plan file and the worker artifacts. Check:
- every plan node is ticked and truly meets its acceptance criterion;
- the changes (git diff/status where available) are consistent, minimal, and nothing is broken or overbuilt;
- nothing was silently skipped or faked.

Reply with exactly one of:
- "PASS" followed by 2-3 sentences of assessment; or
- "FIX:" followed by a numbered list of concrete issues, each naming the file and what to change.'

root=$(pwd -P)/.pi-subagent-runs
case $0 in
    /*) self=$0 ;;
    *) self=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)/$(basename "$0") ;;
esac
self_dir=$(CDPATH='' cd -- "$(dirname "$self")" && pwd -P)
watch_exit=$self_dir/pi-subagent-watch-exit.ts
extract_script=$self_dir/session-final.js

die() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}

cleanup() {
    [ -z "${skills_tmp:-}" ] || rm -f "$skills_tmp"
    [ -z "${arc_prompt:-}" ] || rm -f "$arc_prompt"
}
trap cleanup 0

usage() {
    cat >&2 <<'EOF'
usage:
  pi-subagent.sh start [--async] [--orchestrator-target NAME] [--agent NAME] [--model MODEL --effort LEVEL] [--skill PATH] PROMPT_FILE
  pi-subagent.sh follow-up ID [--async] [--orchestrator-target NAME] [--agent NAME] [--model MODEL --effort LEVEL] [--skill PATH] PROMPT_FILE
  pi-subagent.sh plan [--async] [--orchestrator-target NAME] [--model MODEL --effort LEVEL] [--skill PATH] PROMPT_FILE
  pi-subagent.sh work ID [NODE...] [--async] [--model MODEL --effort LEVEL] [--agent ROLE]
  pi-subagent.sh critique ID [--async] [--orchestrator-target NAME] [--model MODEL --effort LEVEL]
  pi-subagent.sh status ID
  pi-subagent.sh wait ID
  pi-subagent.sh list
  pi-subagent.sh stop ID
EOF
    exit 2
}

valid_id() {
    case $1 in ''|.|..|*/*) return 1 ;; esac
}

run_dir_for() {
    valid_id "$1" || die "invalid subagent session id: $1"
    printf '%s/%s\n' "$root" "$1"
}

read_profile() {
    { IFS= read -r model && IFS= read -r effort; } < "$1/profile" || die "invalid model profile: $1/profile"
}

read_agent() {
    agent=$(cat "$1/agent" 2>/dev/null) || agent=$DEFAULT_AGENT
    [ -n "$agent" ] || agent=$DEFAULT_AGENT
}

child_name_for() {
    read_agent "$1"
    printf '%s-%s' "$agent" "${1##*/}" | sed 's/[^a-zA-Z0-9._-]/-/g'
}

shell_quote() {
    quoted=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
    printf "'%s'" "$quoted"
}

resolve_orchestrator_target() {
    saved=$1
    if [ -n "$opt_target" ]; then
        orchestrator_target=$opt_target
    elif [ -n "$saved" ]; then
        orchestrator_target=$saved
    elif [ -n "${PI_SESSION_ID:-}" ]; then
        sid=${PI_SESSION_ID#session-}
        # Unnamed sessions register with pi-intercom as
        # subagent-chat-<first 18 chars of the session id>; match that so
        # child completion reports route back to the orchestrator.
        short=$(printf '%s' "$sid" | cut -c1-18)
        if [ -n "$short" ]; then
            orchestrator_target=subagent-chat-$short
        else
            orchestrator_target=
        fi
    else
        orchestrator_target=
    fi
}

latest_turn() {
    run_dir=$1
    n=1
    latest=
    while :; do
        turn=$(printf '%03d' "$n")
        [ -e "$run_dir/turn-$turn.prompt.md" ] || break
        latest=$turn
        n=$((n + 1))
    done
    [ -n "$latest" ] || return 1
    printf '%s\n' "$latest"
}

finish_turn() {
    run_dir=$1
    turn=$2
    code=$3
    partial=$run_dir/turn-$turn.result.partial.md
    result=$run_dir/turn-$turn.result.md
    if [ "$code" -eq 0 ]; then
        mv "$partial" "$result"
    fi
    rm -rf "$run_dir/busy"
    marker=$run_dir/.turn-$turn.exit-code.$$
    printf '%s\n' "$code" > "$marker"
    mv "$marker" "$run_dir/turn-$turn.exit-code"
}

run_turn() {
    run_dir=$1
    turn=$2
    mode=${3:-headless}
    read_profile "$run_dir"
    read_agent "$run_dir"
    turn_stage=$(cat "$run_dir/turn-$turn.stage" 2>/dev/null) || turn_stage=
    child_index=$(cat "$run_dir/index" 2>/dev/null) || child_index=0
    [ -n "$child_index" ] || child_index=0
    orchestrator_target=$(cat "$run_dir/orchestrator-target" 2>/dev/null) || orchestrator_target=
    run_id=${run_dir##*/}
    child_name=$(child_name_for "$run_dir")
    prompt=$run_dir/turn-$turn.prompt.md
    stderr=$run_dir/turn-$turn.stderr.log
    partial=$run_dir/turn-$turn.result.partial.md
    skills=$run_dir/turn-$turn.skills
    session=$run_dir/session.jsonl
    pi_command=${PI_SUBAGENT_PI:-pi}

    intercom_ext=${PI_SUBAGENT_INTERCOM_EXTENSION:-$HOME/.pi/agent/npm/node_modules/pi-intercom/index.ts}
    if [ ! -f "$intercom_ext" ]; then
        printf 'warning: pi-intercom extension not found at %s; child runs without intercom\n' "$intercom_ext" >&2
        intercom_ext=
    fi

    printf '%s\n' "$$" > "$run_dir/busy/runner-pid"
    set -- -n "$child_name" --model "$model" --thinking "$effort" --session "$session" --no-extensions
    [ -n "$intercom_ext" ] && set -- "$@" --extension "$intercom_ext"
    if [ "$mode" = pane ]; then
        # Pane mode runs the real pi TUI so the user can watch the subagent
        # work. The watch-exit extension shuts pi down once the agent settles.
        [ -n "$watch_exit" ] && [ -f "$watch_exit" ] && set -- "$@" --extension "$watch_exit"
    else
        # Headless mode keeps -p (print/single-shot): process the prompt and exit.
        set -- -p "$@"
    fi
    set -- "$@" --no-skills
    while IFS= read -r skill; do
        [ -n "$skill" ] && set -- "$@" --skill "$skill"
    done < "$skills"
    case $turn_stage in
        # Planner and critic stages are read-only by contract: strip edit/write
        # so a model that ignores the prompt boundary still cannot implement.
        plan | critique) set -- "$@" --exclude-tools edit,write ;;
    esac
    set -- "$@" "@$prompt"

    bridge_env=
    if [ -n "$orchestrator_target" ]; then
        bridge_env="PI_SUBAGENT_ORCHESTRATOR_TARGET=$orchestrator_target PI_SUBAGENT_RUN_ID=$run_id PI_SUBAGENT_CHILD_AGENT=$agent PI_SUBAGENT_CHILD_INDEX=$child_index"
    fi

    child=
    trap '[ -z "$child" ] || kill "$child" 2>/dev/null || :' HUP INT TERM
    # Strip the parent Pi session's bash-tool metadata (docs/environment-variables.md)
    # so the child never inherits a stale PI_SESSION_ID/PI_MODEL/etc. from a
    # different session, then layer on the intercom bridge metadata.
    if [ "$mode" = pane ]; then
        # The child is the real pi TUI writing straight to the pane tty, so
        # there is no stdout pipe to tee. After it exits (watch extension
        # shuts it down once the agent settles), recover the final assistant
        # text and outcome from the session file for the artifacts.
        # shellcheck disable=SC2086 # $bridge_env expands to separate VAR=value words
        env -u PI_SESSION_ID -u PI_SESSION_FILE -u PI_PROVIDER -u PI_MODEL -u PI_REASONING_LEVEL \
            $bridge_env PI_SUBAGENT_INTERCOM_SESSION_NAME="$child_name" \
            "$pi_command" "$@" 2> "$stderr" &
        child=$!
        pid_tmp=$run_dir/.turn-$turn.pid.$$
        printf '%s\n' "$child" > "$pid_tmp"
        mv "$pid_tmp" "$run_dir/turn-$turn.pid"
        wait "$child"
        code=$?
        if [ -f "$session" ] && command -v node >/dev/null 2>&1; then
            sess_code=$(node "$extract_script" "$session" "$partial" 2>/dev/null)
            [ -n "$sess_code" ] && [ "$code" -eq 0 ] && code=$sess_code
        fi
        # A short response can scroll off the top of a tall pane, leaving only
        # blank rows and the eventual "Pane is dead" banner visible. Recap the
        # tail so the bottom of the pane always shows something meaningful.
        printf '\n----- last output (exit %s) -----\n' "$code"
        tail -n 20 "$partial" 2>/dev/null
    else
        # shellcheck disable=SC2086 # $bridge_env expands to separate VAR=value words
        env -u PI_SESSION_ID -u PI_SESSION_FILE -u PI_PROVIDER -u PI_MODEL -u PI_REASONING_LEVEL \
            $bridge_env PI_SUBAGENT_INTERCOM_SESSION_NAME="$child_name" \
            "$pi_command" "$@" > "$partial" 2> "$stderr" &
        child=$!
        pid_tmp=$run_dir/.turn-$turn.pid.$$
        printf '%s\n' "$child" > "$pid_tmp"
        mv "$pid_tmp" "$run_dir/turn-$turn.pid"
        wait "$child"
        code=$?
    fi
    trap - HUP INT TERM
    finish_turn "$run_dir" "$turn" "$code"
    exit "$code"
}

add_git_exclude() {
    exclude=$(git rev-parse --git-path info/exclude 2>/dev/null) || return 0
    line=/.pi-subagent-runs/
    [ -f "$exclude" ] && grep -Fqx "$line" "$exclude" && return 0
    mkdir -p "$(dirname "$exclude")"
    printf '%s\n' "$line" >> "$exclude"
}

parse_launch_options() {
    async=false
    model=
    effort=
    agent=
    opt_target=
    skills_tmp=$(mktemp "${TMPDIR:-/tmp}/pi-subagent-skills.XXXXXX") || die 'could not create temporary file'
    while [ "$#" -gt 0 ]; do
        case $1 in
            --async) async=true; shift ;;
            --model) [ "$#" -ge 2 ] || die '--model requires a value'; model=$2; shift 2 ;;
            --effort) [ "$#" -ge 2 ] || die '--effort requires a value'; effort=$2; shift 2 ;;
            --agent) [ "$#" -ge 2 ] || die '--agent requires a value'; agent=$2; shift 2 ;;
            --orchestrator-target) [ "$#" -ge 2 ] || die '--orchestrator-target requires a value'; opt_target=$2; shift 2 ;;
            --skill)
                [ "$#" -ge 2 ] || die '--skill requires a path'
                [ -e "$2" ] || die "skill not found: $2"
                printf '%s\n' "$2" >> "$skills_tmp"
                shift 2
                ;;
            --) shift; break ;;
            -*) die "unknown option: $1" ;;
            *) break ;;
        esac
    done
    [ "$#" -eq 1 ] || usage
    prompt_source=$1
    [ -f "$prompt_source" ] || die "prompt file not found: $prompt_source"
    if { [ -n "$model" ] && [ -z "$effort" ]; } || { [ -z "$model" ] && [ -n "$effort" ]; }; then
        die 'model overrides require both --model and --effort'
    fi
}

emit_paths() {
    run_dir=$1
    turn=$2
    printf 'id=%s\n' "${run_dir##*/}"
    printf 'session=%s/session.jsonl\n' "$run_dir"
    printf 'turn=%s\n' "$turn"
    [ -f "$run_dir/plan.md" ] && printf 'plan=%s/plan.md\n' "$run_dir"
    printf 'prompt=%s/turn-%s.prompt.md\n' "$run_dir" "$turn"
    printf 'result=%s/turn-%s.result.md\n' "$run_dir" "$turn"
    printf 'stderr=%s/turn-%s.stderr.log\n' "$run_dir" "$turn"
    printf 'exit_code=%s/turn-%s.exit-code\n' "$run_dir" "$turn"
    printf 'window=%s\n' "$WATCH_WINDOW"
}

boundary_for() {
    case ${stage:-} in
        plan) stage_text=$PLAN_STAGE ;;
        work) stage_text=$WORK_STAGE ;;
        critique) stage_text=$CRITIQUE_STAGE ;;
        *) stage_text='Execute the assigned task directly. Do not spawn further agents.' ;;
    esac
    printf '%s\n\n%s\n' "$stage_text" "$SUPERVISOR_BLOCK" | sed "s|%RUN_DIR%|$run_dir|g"
}

prepare_turn() {
    run_dir=$1
    turn=$2
    {
        boundary_for
        printf '\n'
        cat "$prompt_source"
    } > "$run_dir/turn-$turn.prompt.md"
    printf '%s\n' "${stage:-}" > "$run_dir/turn-$turn.stage"
    mv "$skills_tmp" "$run_dir/turn-$turn.skills"
}

resolve_win() {
    win=
    session=
    if [ -n "${TMUX:-}" ]; then
        session=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null) || session=
        [ -n "$session" ] || session=$(tmux display-message -p '#{session_name}' 2>/dev/null) || session=
    else
        # Outside tmux, the watch window is pinned to a dedicated session.
        session=$WATCH_WINDOW
    fi
    [ -n "$session" ] && win=$(tmux list-windows -t "$session" -F '#{window_id} #{window_name}' 2>/dev/null | awk -v name="$WATCH_WINDOW" '$2 == name { print $1; exit }')
}

sweep_dead_panes() {
    # A dead pane (remain-on-exit) means its subagent turn already finished -
    # the wrapping __run script only exits after writing the turn's exit
    # code. Close it so the watch window doesn't accumulate finished panes;
    # tmux removes a window itself once its last pane is gone.
    tmux list-panes -t "$1" -F '#{pane_id} #{pane_dead}' 2>/dev/null |
        while IFS=' ' read -r dead_pane_id dead_pane_flag; do
            [ "$dead_pane_flag" = 1 ] && tmux kill-pane -t "$dead_pane_id" >/dev/null 2>&1
        done
}

watch_launch() {
    run_dir=$1
    turn=$2
    if ! command -v tmux >/dev/null 2>&1; then
        printf 'notice: tmux not found; subagent runs headless\n' >&2
        return 1
    fi
    if ! tmux has-session >/dev/null 2>&1; then
        printf 'notice: no running tmux server; subagent runs headless\n' >&2
        return 1
    fi
    cmd="$(shell_quote "$self") __run $(shell_quote "$run_dir") $(shell_quote "$turn") pane"
    cwd=$(pwd -P)
    title="$(child_name_for "$run_dir") turn-$turn"
    # The tmux server spawns pane commands with its own environment, not the
    # caller's, so forward the knobs the runner needs via -e.
    set --
    [ -n "${PI_SUBAGENT_PI:-}" ] && set -- "$@" -e "PI_SUBAGENT_PI=$PI_SUBAGENT_PI"
    [ -n "${PI_SUBAGENT_INTERCOM_EXTENSION:-}" ] && set -- "$@" -e "PI_SUBAGENT_INTERCOM_EXTENSION=$PI_SUBAGENT_INTERCOM_EXTENSION"
    resolve_win
    # Close out any siblings that already finished before adding a new pane.
    [ -n "$win" ] && sweep_dead_panes "$win"
    pane_info=
    if [ -n "$win" ]; then
        pane_info=$(tmux split-window "$@" -P -F '#{pane_id} #{pane_pid}' -t "$win" -c "$cwd" "$cmd") || return 1
        tmux select-layout -t "$win" tiled >/dev/null 2>&1 || :
    elif [ -n "${TMUX:-}" ]; then
        pane_info=$(tmux new-window "$@" -P -F '#{pane_id} #{pane_pid}' -n "$WATCH_WINDOW" -c "$cwd" "$cmd") || return 1
    else
        # Outside tmux, pin the watch window to a dedicated session.
        pane_info=$(tmux new-session -d "$@" -P -F '#{pane_id} #{pane_pid}' -s "$WATCH_WINDOW" -n "$WATCH_WINDOW" -c "$cwd" "$cmd") || return 1
    fi
    pane_id=${pane_info%% *}
    pane_pid=${pane_info#* }
    pane_win=$(tmux display-message -p -t "$pane_id" '#{window_id}' 2>/dev/null) || pane_win=
    [ -n "$pane_win" ] && tmux set-option -w -t "$pane_win" remain-on-exit on >/dev/null 2>&1
    tmux select-pane -t "$pane_id" -T "$title" >/dev/null 2>&1 || :
    printf 'watching in tmux session %s, pane %s\n' "$session" "$pane_id" >&2
    printf '%s\n' "$pane_pid"
}

process_is_running() {
    [ -n "$1" ] && kill -0 "$1" 2>/dev/null
}

turn_processes() {
    run_dir=$1
    turn=$2
    pid=
    runner=
    [ ! -f "$run_dir/turn-$turn.pid" ] || pid=$(cat "$run_dir/turn-$turn.pid")
    [ ! -f "$run_dir/busy/runner-pid" ] || runner=$(cat "$run_dir/busy/runner-pid")
}

poll_turn_exit() {
    run_dir=$1
    turn=$2
    pane_pid=$3
    exit_marker=$run_dir/turn-$turn.exit-code
    grace=0
    while [ ! -e "$exit_marker" ]; do
        turn_processes "$run_dir" "$turn"
        if process_is_running "$pid" || process_is_running "$runner"; then
            grace=0
            sleep 1
            continue
        fi
        if [ ! -d "$run_dir/busy" ]; then
            # Runner finished; the exit marker may still be landing.
            sleep 1
            break
        fi
        if process_is_running "$pane_pid"; then
            # Busy marker exists but no child observed yet: the pane shell
            # may still be starting up. Give it time.
            grace=$((grace + 1))
            [ "$grace" -gt 60 ] && break
            sleep 1
            continue
        fi
        break
    done
    [ -e "$exit_marker" ] || finish_turn "$run_dir" "$turn" 143
    poll_code=$(cat "$run_dir/turn-$turn.exit-code" 2>/dev/null) || poll_code=1
    return "$poll_code"
}

launch_turn() {
    run_dir=$1
    turn=$2
    emit_paths "$run_dir" "$turn"
    runner=$(watch_launch "$run_dir" "$turn") && {
        if [ "$async" = true ]; then
            while [ ! -e "$run_dir/turn-$turn.pid" ] && [ ! -e "$run_dir/turn-$turn.exit-code" ]; do
                kill -0 "$runner" 2>/dev/null || break
                sleep 1
            done
            return 0
        fi
        poll_turn_exit "$run_dir" "$turn" "$runner"
        return $?
    }
    if [ "$async" = true ]; then
        nohup "$self" __run "$run_dir" "$turn" headless </dev/null >/dev/null 2>&1 &
        runner=$!
        while [ ! -e "$run_dir/turn-$turn.pid" ] && [ ! -e "$run_dir/turn-$turn.exit-code" ]; do
            kill -0 "$runner" 2>/dev/null || break
            sleep 1
        done
        return 0
    fi
    run_turn "$run_dir" "$turn" headless
}

start_body() {
    mkdir -p "$root"
    add_git_exclude
    child_index=0
    for d in "$root"/task.*; do
        [ -d "$d" ] && child_index=$((child_index + 1))
    done
    run_dir=$(mktemp -d "$root/task.XXXXXX") || die 'could not create subagent session directory'
    printf '%s\n%s\n' "$model" "$effort" > "$run_dir/profile"
    printf '%s\n' "$agent" > "$run_dir/agent"
    printf '%s\n' "$child_index" > "$run_dir/index"
    resolve_orchestrator_target ""
    if [ -n "$orchestrator_target" ]; then
        printf '%s\n' "$orchestrator_target" > "$run_dir/orchestrator-target"
    fi
    if [ "${stage:-}" = plan ] && base_ref=$(git rev-parse HEAD 2>/dev/null); then
        printf '%s\n' "$base_ref" > "$run_dir/base-ref"
    fi
    mkdir "$run_dir/busy"
    turn=001
    prepare_turn "$run_dir" "$turn"
    launch_turn "$run_dir" "$turn"
}

start() {
    parse_launch_options "$@"
    [ -n "$model" ] || model=$DEFAULT_MODEL
    [ -n "$effort" ] || effort=$DEFAULT_EFFORT
    [ -n "$agent" ] || agent=$DEFAULT_AGENT
    start_body
}

plan_run() {
    stage=plan
    parse_launch_options "$@"
    [ -n "$model" ] || model=$PLANNER_MODEL
    [ -n "$effort" ] || effort=$PLANNER_EFFORT
    [ -n "$agent" ] || agent=planner
    start_body
}

work_run() {
    [ "$#" -ge 1 ] || usage
    id=$1
    shift
    run_dir=$(run_dir_for "$id")
    [ -d "$run_dir" ] || die "subagent session not found: $id"
    [ -f "$run_dir/plan.md" ] || die "no plan.md in $run_dir; run 'plan' first"
    # Rebuild the argument list: --options pass through, bare words are node specs.
    nodes=
    opts=
    work_model=
    work_effort=
    work_agent=
    while [ "$#" -gt 0 ]; do
        case $1 in
            --async) opts="$opts $1"; shift ;;
            --model) [ "$#" -ge 2 ] || die '--model requires a value'; work_model=$2; shift 2 ;;
            --effort) [ "$#" -ge 2 ] || die '--effort requires a value'; work_effort=$2; shift 2 ;;
            --agent) [ "$#" -ge 2 ] || die '--agent requires a value'; work_agent=$2; shift 2 ;;
            --*) die "unknown option for work: $1" ;;
            *) nodes="$nodes $1"; shift ;;
        esac
    done
    if { [ -n "$work_model" ] && [ -z "$work_effort" ]; } || { [ -z "$work_model" ] && [ -n "$work_effort" ]; }; then
        die 'model overrides require both --model and --effort'
    fi
    # Work defaults to the ordinary worker profile and agent label regardless
    # of what the planner used, so the commodity model carries execution by
    # default and pane titles/reports reflect the current stage; pass
    # --model/--effort/--agent to use something else for this turn.
    [ -n "$work_model" ] || work_model=$DEFAULT_MODEL
    [ -n "$work_effort" ] || work_effort=$DEFAULT_EFFORT
    [ -n "$work_agent" ] || work_agent=$DEFAULT_AGENT
    opts="$opts --model $work_model --effort $work_effort --agent $work_agent"
    arc_prompt=$(mktemp "${TMPDIR:-/tmp}/pi-subagent-arc.XXXXXX") || die 'could not create temporary file'
    {
        printf 'Work the plan at %s/plan.md.\n' "$run_dir"
        [ -z "$nodes" ] || printf 'Focus on node(s):%s.\n' "$nodes"
    } > "$arc_prompt"
    stage=work
    # shellcheck disable=SC2086 # $opts expands to separate option words
    follow_up "$id" $opts "$arc_prompt"
}

critique_run() {
    [ "$#" -ge 1 ] || usage
    id=$1
    shift
    run_dir=$(run_dir_for "$id")
    [ -d "$run_dir" ] || die "subagent session not found: $id"
    [ -f "$run_dir/plan.md" ] || die "no plan.md in $run_dir; nothing to critique"
    arc_prompt=$(mktemp "${TMPDIR:-/tmp}/pi-subagent-arc.XXXXXX") || die 'could not create temporary file'
    {
        printf 'Review the completed run %s.\n' "$id"
        printf 'Plan: %s/plan.md\n' "$run_dir"
        printf 'Worker artifacts (turn prompts, results, session.jsonl): %s\n' "$run_dir"
        if [ -f "$run_dir/base-ref" ]; then
            printf 'Diff since the arc started: git diff %s\n' "$(cat "$run_dir/base-ref")"
        fi
    } > "$arc_prompt"
    stage=critique
    parse_launch_options "$@" "$arc_prompt"
    [ -n "$model" ] || model=$CRITIC_MODEL
    [ -n "$effort" ] || effort=$CRITIC_EFFORT
    [ -n "$agent" ] || agent=critic
    start_body
}

follow_up() {
    [ "$#" -ge 2 ] || usage
    id=$1
    shift
    run_dir=$(run_dir_for "$id")
    [ -d "$run_dir" ] || die "subagent session not found: $id"
    parse_launch_options "$@"
    if ! mkdir "$run_dir/busy" 2>/dev/null; then
        rm -f "$skills_tmp"
        die "subagent session is busy: $id"
    fi
    if [ -n "$model" ]; then
        profile_tmp=$run_dir/.profile.$$
        printf '%s\n%s\n' "$model" "$effort" > "$profile_tmp"
        mv "$profile_tmp" "$run_dir/profile"
    fi
    if [ -n "$agent" ]; then
        agent_tmp=$run_dir/.agent.$$
        printf '%s\n' "$agent" > "$agent_tmp"
        mv "$agent_tmp" "$run_dir/agent"
    fi
    resolve_orchestrator_target "$(cat "$run_dir/orchestrator-target" 2>/dev/null)"
    if [ -n "$orchestrator_target" ]; then
        target_tmp=$run_dir/.orchestrator-target.$$
        printf '%s\n' "$orchestrator_target" > "$target_tmp"
        mv "$target_tmp" "$run_dir/orchestrator-target"
    fi
    n=1
    while [ -e "$run_dir/turn-$(printf '%03d' "$n").prompt.md" ]; do n=$((n + 1)); done
    turn=$(printf '%03d' "$n")
    prepare_turn "$run_dir" "$turn"
    launch_turn "$run_dir" "$turn"
}

status_session() {
    [ "$#" -eq 1 ] || usage
    id=$1
    run_dir=$(run_dir_for "$id")
    [ -d "$run_dir" ] || die "subagent session not found: $id"
    turn=$(latest_turn "$run_dir") || die "subagent session has no turns: $id"
    marker=$run_dir/turn-$turn.exit-code
    code=
    if [ -e "$marker" ]; then
        code=$(cat "$marker")
        if [ "$code" -eq 0 ] && [ -f "$run_dir/turn-$turn.result.md" ]; then
            state=succeeded
        else
            state=failed
        fi
    else
        turn_processes "$run_dir" "$turn"
        if [ -d "$run_dir/busy" ] && { process_is_running "$pid" || process_is_running "$runner"; }; then
            state=running
        else
            state=incomplete
        fi
    fi
    printf 'id=%s turn=%s status=%s' "$id" "$turn" "$state"
    [ -z "$code" ] || printf ' code=%s' "$code"
    if [ -f "$run_dir/plan.md" ]; then
        plan_total=$(grep -c '^- \[' "$run_dir/plan.md" 2>/dev/null)
        plan_done=$(grep -c '^- \[x\]' "$run_dir/plan.md" 2>/dev/null)
        printf ' plan=%s/%s' "$plan_done" "$plan_total"
    fi
    printf ' result=%s/turn-%s.result.md stderr=%s/turn-%s.stderr.log\n' "$run_dir" "$turn" "$run_dir" "$turn"
}

wait_for_session() {
    [ "$#" -eq 1 ] || usage
    id=$1
    run_dir=$(run_dir_for "$id")
    [ -d "$run_dir" ] || die "subagent session not found: $id"
    turn=$(latest_turn "$run_dir") || die "subagent session has no turns: $id"
    marker=$run_dir/turn-$turn.exit-code
    while [ ! -e "$marker" ]; do
        [ -d "$run_dir/busy" ] || die "turn $turn is incomplete and has no busy marker"
        turn_processes "$run_dir" "$turn"
        if ! process_is_running "$pid" && ! process_is_running "$runner"; then
            die "turn $turn is incomplete and no process is running"
        fi
        sleep 1
    done
    code=$(cat "$marker")
    emit_paths "$run_dir" "$turn"
    return "$code"
}

list_sessions() {
    [ "$#" -eq 0 ] || usage
    if command -v tmux >/dev/null 2>&1 && tmux has-session >/dev/null 2>&1; then
        resolve_win
        [ -n "$win" ] && sweep_dead_panes "$win"
    fi
    [ -d "$root" ] || return 0
    for run_dir in "$root"/*; do
        [ -d "$run_dir" ] || continue
        status_session "${run_dir##*/}"
    done
}

stop_session() {
    [ "$#" -eq 1 ] || usage
    id=$1
    run_dir=$(run_dir_for "$id")
    [ -d "$run_dir" ] || die "subagent session not found: $id"
    turn=$(latest_turn "$run_dir") || die "subagent session has no turns: $id"
    if [ -e "$run_dir/turn-$turn.exit-code" ]; then
        status_session "$id"
        return 0
    fi
    turn_processes "$run_dir" "$turn"
    if process_is_running "$pid"; then
        kill "$pid"
        printf 'stopping id=%s turn=%s pid=%s\n' "$id" "$turn" "$pid"
    elif process_is_running "$runner"; then
        kill "$runner"
        printf 'stopping id=%s turn=%s pid=%s\n' "$id" "$turn" "$runner"
    else
        finish_turn "$run_dir" "$turn" 143
        printf 'stopped incomplete id=%s turn=%s\n' "$id" "$turn"
    fi
}

command=${1:-}
[ "$#" -gt 0 ] && shift
stage=
case $command in
    start) start "$@" ;;
    follow-up) follow_up "$@" ;;
    plan) plan_run "$@" ;;
    work) work_run "$@" ;;
    critique) critique_run "$@" ;;
    status) status_session "$@" ;;
    wait) wait_for_session "$@" ;;
    list) list_sessions "$@" ;;
    stop) stop_session "$@" ;;
    __run) [ "$#" -eq 3 ] || exit 2; run_turn "$1" "$2" "$3" ;;
    *) usage ;;
esac

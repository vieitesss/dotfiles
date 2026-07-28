#!/bin/sh
set -u
umask 077

DEFAULT_MODEL=openai-codex/gpt-5.6-luna
DEFAULT_EFFORT=max
BOUNDARY='Execute the assigned task directly. Do not spawn further agents. Return a self-contained final response.'
root=$(pwd -P)/.pi-subagent-runs
case $0 in
    /*) self=$0 ;;
    *) self=$(CDPATH='' cd -- "$(dirname "$0")" && pwd -P)/$(basename "$0") ;;
esac

die() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}

cleanup() {
    [ -z "${skills_tmp:-}" ] || rm -f "$skills_tmp"
}
trap cleanup 0

usage() {
    cat >&2 <<'EOF'
usage:
  pi-subagent.sh start [--async] [--model MODEL --effort LEVEL] [--skill PATH] PROMPT_FILE
  pi-subagent.sh follow-up ID [--async] [--model MODEL --effort LEVEL] [--skill PATH] PROMPT_FILE
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
    read_profile "$run_dir"
    prompt=$run_dir/turn-$turn.prompt.md
    stderr=$run_dir/turn-$turn.stderr.log
    partial=$run_dir/turn-$turn.result.partial.md
    skills=$run_dir/turn-$turn.skills
    session=$run_dir/session.jsonl
    pi_command=${PI_SUBAGENT_PI:-pi}

    printf '%s\n' "$$" > "$run_dir/busy/runner-pid"
    set -- -p --model "$model" --thinking "$effort" --session "$session" --no-extensions --no-skills
    while IFS= read -r skill; do
        [ -n "$skill" ] && set -- "$@" --skill "$skill"
    done < "$skills"
    set -- "$@" "@$prompt"

    child=
    trap '[ -z "$child" ] || kill "$child" 2>/dev/null || :' HUP INT TERM
    "$pi_command" "$@" > "$partial" 2> "$stderr" &
    child=$!
    pid_tmp=$run_dir/.turn-$turn.pid.$$
    printf '%s\n' "$child" > "$pid_tmp"
    mv "$pid_tmp" "$run_dir/turn-$turn.pid"
    wait "$child"
    code=$?
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
    skills_tmp=$(mktemp "${TMPDIR:-/tmp}/pi-subagent-skills.XXXXXX") || die 'could not create temporary file'
    while [ "$#" -gt 0 ]; do
        case $1 in
            --async) async=true; shift ;;
            --model) [ "$#" -ge 2 ] || die '--model requires a value'; model=$2; shift 2 ;;
            --effort) [ "$#" -ge 2 ] || die '--effort requires a value'; effort=$2; shift 2 ;;
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
    printf 'prompt=%s/turn-%s.prompt.md\n' "$run_dir" "$turn"
    printf 'result=%s/turn-%s.result.md\n' "$run_dir" "$turn"
    printf 'stderr=%s/turn-%s.stderr.log\n' "$run_dir" "$turn"
    printf 'exit_code=%s/turn-%s.exit-code\n' "$run_dir" "$turn"
}

prepare_turn() {
    run_dir=$1
    turn=$2
    {
        printf '%s\n\n' "$BOUNDARY"
        cat "$prompt_source"
    } > "$run_dir/turn-$turn.prompt.md"
    mv "$skills_tmp" "$run_dir/turn-$turn.skills"
}

launch_turn() {
    run_dir=$1
    turn=$2
    emit_paths "$run_dir" "$turn"
    if [ "$async" = true ]; then
        nohup "$self" __run "$run_dir" "$turn" </dev/null >/dev/null 2>&1 &
        runner=$!
        while [ ! -e "$run_dir/turn-$turn.pid" ] && [ ! -e "$run_dir/turn-$turn.exit-code" ]; do
            kill -0 "$runner" 2>/dev/null || break
            sleep 1
        done
        return 0
    fi
    run_turn "$run_dir" "$turn"
}

start() {
    parse_launch_options "$@"
    [ -n "$model" ] || model=$DEFAULT_MODEL
    [ -n "$effort" ] || effort=$DEFAULT_EFFORT
    mkdir -p "$root"
    add_git_exclude
    run_dir=$(mktemp -d "$root/task.XXXXXX") || die 'could not create subagent session directory'
    printf '%s\n%s\n' "$model" "$effort" > "$run_dir/profile"
    mkdir "$run_dir/busy"
    turn=001
    prepare_turn "$run_dir" "$turn"
    launch_turn "$run_dir" "$turn"
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
    n=1
    while [ -e "$run_dir/turn-$(printf '%03d' "$n").prompt.md" ]; do n=$((n + 1)); done
    turn=$(printf '%03d' "$n")
    prepare_turn "$run_dir" "$turn"
    launch_turn "$run_dir" "$turn"
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
case $command in
    start) start "$@" ;;
    follow-up) follow_up "$@" ;;
    status) status_session "$@" ;;
    wait) wait_for_session "$@" ;;
    list) list_sessions "$@" ;;
    stop) stop_session "$@" ;;
    __run) [ "$#" -eq 2 ] || exit 2; run_turn "$1" "$2" ;;
    *) usage ;;
esac

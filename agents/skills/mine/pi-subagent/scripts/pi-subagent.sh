#!/bin/sh
set -u
umask 077

DEFAULT_MODEL=opencode-go/deepseek-v4.1-flash
DEFAULT_EFFORT=max
DEFAULT_AGENT=implementer
PLANNER_MODEL=github-copilot/grok-4.6
PLANNER_EFFORT=xhigh
CRITIC_MODEL=github-copilot/kimi-k3
CRITIC_EFFORT=high
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
tmux_helper=$self_dir/pi-subagent-tmux.sh

die() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}

# Close only the pane this process claimed in __run. Inherited
# PI_SUBAGENT_HERDR_PANE is not ownership; status/list/wait/stop must not
# close a parent pane. Always return 0 so the EXIT trap can restore $rc.
herdr_owned_pane=
herdr_close_watch_pane() {
    pane=${herdr_owned_pane:-}
    [ -n "$pane" ] || return 0
    herdr_owned_pane=
    herdr pane close "$pane" >/dev/null || printf 'warning: herdr pane close failed for %s; turn result left unchanged\n' "$pane" >&2
    return 0
}

cleanup() {
    [ -z "${skills_tmp:-}" ] || rm -f "$skills_tmp"
    [ -z "${arc_prompt:-}" ] || rm -f "$arc_prompt"
    herdr_close_watch_pane
}
trap 'rc=$?; cleanup; exit $rc' EXIT

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
    # Marker before busy removal: every observer checks the marker first, so
    # publishing completion before dropping the busy flag leaves no gap in
    # which a turn looks neither running nor finished.
    marker=$run_dir/.turn-$turn.exit-code.$$
    printf '%s\n' "$code" > "$marker"
    mv "$marker" "$run_dir/turn-$turn.exit-code"
    rm -rf "$run_dir/busy"
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
    # Drop PI_SUBAGENT_HERDR_PANE so a nested helper spawned from this Pi
    # cannot close this watch pane; keep PI_SUBAGENT_HERDR_INNER so a nested
    # launch cannot re-enter herdr_launch.
    if [ "$mode" = pane ]; then
        # The child is the real pi TUI writing straight to the pane tty, so
        # there is no stdout pipe to tee. After it exits (watch extension
        # shuts it down once the agent settles), recover the final assistant
        # text and outcome from the session file for the artifacts.
        # shellcheck disable=SC2086 # $bridge_env expands to separate VAR=value words
        env -u PI_SESSION_ID -u PI_SESSION_FILE -u PI_PROVIDER -u PI_MODEL -u PI_REASONING_LEVEL -u PI_SUBAGENT_HERDR_PANE \
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
        env -u PI_SESSION_ID -u PI_SESSION_FILE -u PI_PROVIDER -u PI_MODEL -u PI_REASONING_LEVEL -u PI_SUBAGENT_HERDR_PANE \
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
    # Pane close is the EXIT trap (herdr_close_watch_pane): after finalize
    # on this path, and also on early die(), without replacing $code.
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

# Watch backend selection for the non-Herdr path. tmux is the only backend,
# used solely when tmux is installed and the supervisor sits inside a live
# tmux session; otherwise the turn runs headless with an explicit watch=none
# reason. All tmux work lives in pi-subagent-tmux.sh (invoked, never sourced).
# Herdr spawn is chosen in launch_turn when HERDR_ENV=1 (outer only), not
# here. This selector must not grow a plugin framework, and no branch here
# may invent a dedicated session: without a supervisor session there is
# nothing to watch in.
watch_launch() {
    run_dir=$1
    turn=$2
    # Contract: print exactly one watch line, then (tmux only) the pane pid
    # on the next line. launch_turn replays the first line to stdout and
    # keeps the pid for its wait/poll. NOTE: this function runs inside a
    # command substitution, so it must only return a status — the fail-hard
    # die() for a failed tmux setup happens in launch_turn (main shell),
    # keyed off the watch=failed line. A die() here would exit just the
    # subshell and silently fall back to headless.
    if detect_out=$("$tmux_helper" detect); then
        launch_turn_tmux "$run_dir" "$turn"
        return $?
    fi
    watch_reason=$(printf '%s\n' "$detect_out" | sed -n 's/^reason=//p' | head -n 1)
    [ -n "$watch_reason" ] || watch_reason=not-inside-tmux
    printf 'watch=none reason=%s\n' "$watch_reason"
    return 1
}

launch_turn_tmux() {
    run_dir=$1
    turn=$2
    cmd="$(shell_quote "$self") __run $(shell_quote "$run_dir") $(shell_quote "$turn") pane"
    cwd=$(pwd -P)
    title="$(child_name_for "$run_dir") turn-$turn"
    launch_err=$run_dir/.watch-launch.$$.err
    if watch_out=$("$tmux_helper" launch "$WATCH_WINDOW" "$title" "$cwd" -- "$cmd" 2>"$launch_err"); then
        rm -f "$launch_err"
    else
        launch_code=$?
        [ -f "$launch_err" ] && cat "$launch_err" >&2
        rm -f "$launch_err" "$run_dir/turn-$turn.pid"
        rm -rf "$run_dir/busy"
        printf 'watch=failed reason=tmux-setup code=%s\n' "$launch_code"
        return 1
    fi
    watch_pane=$(printf '%s\n' "$watch_out" | sed -n 's/^pane=//p' | head -n 1)
    watch_pid=$(printf '%s\n' "$watch_out" | sed -n 's/^pid=//p' | head -n 1)
    watch_session_name=$(printf '%s\n' "$watch_out" | sed -n 's/^session=//p' | head -n 1)
    if [ -z "$watch_pane" ] || [ -z "$watch_pid" ] || [ -z "$watch_session_name" ]; then
        rm -rf "$run_dir/busy"
        printf 'watch=failed reason=tmux-setup code=unusable\n'
        return 1
    fi
    printf 'watch=tmux tmux_session=%s window=%s pane=%s\n' "$watch_session_name" "$WATCH_WINDOW" "$watch_pane"
    printf 'watching in tmux session %s, pane %s\n' "$watch_session_name" "$watch_pane" >&2
    printf '%s\n' "$watch_pid"
}

herdr_die() {
    [ -z "${run_dir:-}" ] || rm -rf "$run_dir/busy"
    die "$*"
}

herdr_json_str() {
    python3 -c '
import json, sys
path = sys.argv[1].split(".")
data = json.load(sys.stdin)
for key in path:
    if not isinstance(data, dict) or key not in data:
        sys.exit(1)
    data = data[key]
if isinstance(data, (dict, list)) or data is None:
    sys.exit(1)
print(data)
' "$1"
}

herdr_tab_ids_labeled() {
    python3 -c '
import json, sys
label = sys.argv[1]
data = json.load(sys.stdin)
for tab in data.get("result", {}).get("tabs") or []:
    if tab.get("label") == label and tab.get("tab_id"):
        print(tab["tab_id"])
' "$1"
}

herdr_pane_ids_in_tab() {
    python3 -c '
import json, sys
tab_id = sys.argv[1]
data = json.load(sys.stdin)
for pane in data.get("result", {}).get("panes") or []:
    if pane.get("tab_id") == tab_id and pane.get("pane_id"):
        print(pane["pane_id"])
' "$1"
}

# Allocate one unfocused pane in this workspace's subagents tab. Sets
# herdr_workspace, herdr_tab, herdr_pane. Fail-hard: never tmux/headless.
herdr_allocate_pane() {
    cwd=$(pwd -P)
    current=$(herdr pane current --current) || herdr_die "herdr pane current --current failed; not falling back to tmux or headless"
    herdr_workspace=$(printf '%s' "$current" | herdr_json_str result.pane.workspace_id) || herdr_die "herdr pane current JSON missing workspace_id; not falling back to tmux or headless"
    supervisor_pane=$(printf '%s' "$current" | herdr_json_str result.pane.pane_id) || herdr_die "herdr pane current JSON missing pane_id; not falling back to tmux or headless"
    supervisor_tab=$(printf '%s' "$current" | herdr_json_str result.pane.tab_id) || herdr_die "herdr pane current JSON missing tab_id; not falling back to tmux or headless"

    tab_list=$(herdr tab list --workspace "$herdr_workspace") || herdr_die "herdr tab list failed; not falling back to tmux or headless"
    subagent_tabs=$(printf '%s' "$tab_list" | herdr_tab_ids_labeled subagents) || herdr_die "herdr tab list JSON unreadable; not falling back to tmux or headless"
    n_tabs=0
    herdr_tab=
    while IFS= read -r tid; do
        [ -n "$tid" ] || continue
        n_tabs=$((n_tabs + 1))
        herdr_tab=$tid
    done <<EOF
$subagent_tabs
EOF

    case $n_tabs in
        0)
            created=$(herdr tab create --workspace "$herdr_workspace" --label subagents --cwd "$cwd" --no-focus) || herdr_die "herdr tab create failed; not falling back to tmux or headless"
            herdr_tab=$(printf '%s' "$created" | herdr_json_str result.tab.tab_id) || herdr_die "herdr tab create JSON missing tab_id; not falling back to tmux or headless"
            herdr_pane=$(printf '%s' "$created" | herdr_json_str result.root_pane.pane_id) || herdr_die "herdr tab create JSON missing root_pane.pane_id; not falling back to tmux or headless"
            ;;
        1)
            panes=$(herdr pane list --workspace "$herdr_workspace") || herdr_die "herdr pane list failed; not falling back to tmux or headless"
            tab_panes=$(printf '%s' "$panes" | herdr_pane_ids_in_tab "$herdr_tab") || herdr_die "herdr pane list JSON unreadable; not falling back to tmux or headless"
            split_target=
            while IFS= read -r pid; do
                [ -n "$pid" ] || continue
                if [ "$pid" != "$supervisor_pane" ]; then
                    split_target=$pid
                    break
                fi
            done <<EOF
$tab_panes
EOF
            if [ -z "$split_target" ]; then
                [ "$supervisor_tab" = "$herdr_tab" ] || herdr_die "subagents tab has no pane to split; not falling back to tmux or headless"
                split_target=$supervisor_pane
            fi
            # Live CLI requires --direction; omitting it fails the split.
            split_json=$(herdr pane split "$split_target" --direction down --no-focus --cwd "$cwd")
            split_st=$?
            if [ "$split_st" -ne 0 ]; then
                [ -n "$split_json" ] && printf '%s\n' "$split_json" >&2
                herdr_die "herdr pane split failed; not falling back to tmux or headless"
            fi
            herdr_pane=$(printf '%s' "$split_json" | herdr_json_str result.pane.pane_id) || herdr_die "herdr pane split JSON missing pane_id; not falling back to tmux or headless"
            ;;
        *)
            herdr_die "duplicate subagents tabs in workspace $herdr_workspace; not falling back to tmux or headless"
            ;;
    esac
    [ -n "$herdr_workspace" ] && [ -n "$herdr_tab" ] && [ -n "$herdr_pane" ] || herdr_die "herdr allocation produced empty ids; not falling back to tmux or headless"
}

# Outer Herdr spawn: allocate a pane, then pane-run inner __run (never start).
# Inner __run does not call launch_turn, so HERDR_ENV=1 cannot recurse.
# Orchestrator target is persisted by the outer process before this runs;
# inner run_turn only reads run_dir/orchestrator-target. --async is outer-only:
# the pane command is always __run ... pane so the Herdr pane keeps a real TUI.
#
# pane run types the command into the pane's shell and sends Enter; a long
# command can be mangled in transit (seen on Linux herdr 0.9.0: an injected
# accept split the line mid-command, and a full-length launch whose Enter
# never landed). Keep the typed command short: a launcher script in the run
# dir carries the real command line and the pane is told only its path.
# (Residual exposure: the typed path is cwd depth + ~45 chars, so a very deep
# cwd can still reach the mangling zone; the launcher must live in the run
# dir, which is rooted at the caller's cwd.)
herdr_launch() {
    run_dir=$1
    turn=$2
    herdr_shell_pid=
    command -v herdr >/dev/null 2>&1 || herdr_die "herdr not found; not falling back to tmux or headless"
    command -v python3 >/dev/null 2>&1 || herdr_die "python3 not found; not falling back to tmux or headless"
    herdr_allocate_pane
    launcher=$run_dir/.launch-$turn.sh
    {
        printf '#!/bin/sh\n'
        printf '# Written by pi-subagent herdr_launch; the watch pane types only this path.\n'
        printf 'exec env -u TMUX -u TMUX_PANE -u PI_SESSION_ID -u PI_SESSION_FILE -u PI_PROVIDER -u PI_MODEL -u PI_REASONING_LEVEL PI_SUBAGENT_HERDR_INNER=1 PI_SUBAGENT_HERDR_PANE=%s %s __run %s %s pane\n' \
            "$(shell_quote "$herdr_pane")" "$(shell_quote "$self")" "$(shell_quote "$run_dir")" "$(shell_quote "$turn")"
    } > "$launcher"
    chmod 700 "$launcher"
    # Quote the typed path: the pane shell word-splits an unquoted launcher
    # under a cwd with spaces/metacharacters and the turn never starts.
    herdr pane run "$herdr_pane" "$(shell_quote "$launcher")" || herdr_die "herdr pane run failed; not falling back to tmux or headless"
    if proc=$(herdr pane process-info --pane "$herdr_pane" 2>/dev/null); then
        herdr_shell_pid=$(printf '%s' "$proc" | herdr_json_str result.process_info.shell_pid) || herdr_shell_pid=
    fi
    printf 'watch=herdr workspace=%s tab=%s pane=%s\n' "$herdr_workspace" "$herdr_tab" "$herdr_pane"
    printf 'watching in herdr workspace %s, tab %s, pane %s\n' "$herdr_workspace" "$herdr_tab" "$herdr_pane" >&2
}

process_is_running() {
    [ -n "$1" ] && kill -0 "$1" 2>/dev/null
}

turn_processes() {
    run_dir=$1
    turn=$2
    pid=
    runner=
    [ ! -f "$run_dir/turn-$turn.pid" ] || pid=$(cat "$run_dir/turn-$turn.pid" 2>/dev/null) || pid=
    [ ! -f "$run_dir/busy/runner-pid" ] || runner=$(cat "$run_dir/busy/runner-pid" 2>/dev/null) || runner=
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
        if [ -z "$pane_pid" ]; then
            # Herdr process-info can fail or omit shell_pid right after
            # pane run. Do not fabricate 143 while busy; wait for the inner
            # helper to publish pid/exit.
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
    if [ "${HERDR_ENV:-}" = 1 ] && [ -z "${PI_SUBAGENT_HERDR_INNER:-}" ]; then
        herdr_launch "$run_dir" "$turn"
        if [ "$async" = true ]; then
            grace=0
            while [ ! -e "$run_dir/turn-$turn.pid" ] && [ ! -e "$run_dir/turn-$turn.exit-code" ]; do
                grace=$((grace + 1))
                [ "$grace" -gt 60 ] && break
                sleep 1
            done
            return 0
        fi
        poll_turn_exit "$run_dir" "$turn" "${herdr_shell_pid:-}"
        return $?
    fi
    # Nested/non-Herdr launches must not inherit a parent watch pane id.
    # Keep PI_SUBAGENT_HERDR_INNER so we still skip herdr_launch.
    unset PI_SUBAGENT_HERDR_PANE
    [ -x "$tmux_helper" ] || die "watch helper missing: $tmux_helper"
    if watch_out=$(watch_launch "$run_dir" "$turn"); then
        printf '%s\n' "$watch_out" | head -n 1
        runner=$(printf '%s\n' "$watch_out" | tail -n 1)
        if [ "$async" = true ]; then
            while [ ! -e "$run_dir/turn-$turn.pid" ] && [ ! -e "$run_dir/turn-$turn.exit-code" ]; do
                kill -0 "$runner" 2>/dev/null || break
                sleep 1
            done
            return 0
        fi
        poll_turn_exit "$run_dir" "$turn" "$runner"
        return $?
    fi
    watch_line=$(printf '%s\n' "$watch_out" | head -n 1)
    printf '%s\n' "$watch_line"
    case $watch_line in
        'watch=none reason='*) : ;;
        *) die "tmux watch setup failed for turn $turn; not falling back to headless" ;;
    esac
    if [ "$async" = true ]; then
        nohup "$self" __run "$run_dir" "$turn" headless </dev/null >/dev/null 2>&1 &
        runner=$!
        while [ ! -e "$run_dir/turn-$turn.pid" ] && [ ! -e "$run_dir/turn-$turn.exit-code" ]; do
            kill -0 "$runner" 2>/dev/null || break
            sleep 1
        done
        return 0
    fi
    if [ -t 1 ]; then
        # Already on this tty: real pi TUI, same as a tmux watch pane. Not a
        # herdr watch backend; outer Herdr spawn never reaches this branch.
        run_turn "$run_dir" "$turn" pane
    else
        run_turn "$run_dir" "$turn" headless
    fi
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
    # Persist before launch_turn: Herdr inner __run has no PI_SESSION_ID and
    # only reads this file. Named --orchestrator-target is stored verbatim.
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
            --orchestrator-target) die 'work does not accept --orchestrator-target; it reuses the session file' ;;
            --*) die "unknown option for work: $1" ;;
            *) nodes="$nodes $1"; shift ;;
        esac
    done
    if { [ -n "$work_model" ] && [ -z "$work_effort" ]; } || { [ -z "$work_model" ] && [ -n "$work_effort" ]; }; then
        die 'model overrides require both --model and --effort'
    fi
    # Work defaults to the implementer profile and agent label regardless
    # of what the planner used, so the implementer model carries execution by
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
    [ -n "$agent" ] || agent=reviewer
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
    # Same persist-before-launch as start: work/follow-up reuse the session
    # file (work rejects --orchestrator-target) unless this turn overrides.
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
    grace=0
    while [ ! -e "$marker" ]; do
        [ -d "$run_dir/busy" ] || die "turn $turn is incomplete and has no busy marker"
        turn_processes "$run_dir" "$turn"
        if process_is_running "$pid" || process_is_running "$runner"; then
            grace=0
        else
            # Busy but no observed process: the runner may be finalizing
            # (result extraction runs after the child exits), so allow a
            # bounded grace period before calling the turn stuck.
            grace=$((grace + 1))
            [ "$grace" -gt 30 ] && die "turn $turn is incomplete and no process is running"
        fi
        sleep 1
    done
    code=$(cat "$marker")
    emit_paths "$run_dir" "$turn"
    return "$code"
}

list_sessions() {
    [ "$#" -eq 0 ] || usage
    if [ -x "$tmux_helper" ]; then
        "$tmux_helper" cleanup "$WATCH_WINDOW" >/dev/null 2>&1 || :
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
    __run)
        # Only this inner pane turn owns cleanup. Capture then drop the env
        # var so later commands in this process cannot treat it as inherited.
        if [ -n "${PI_SUBAGENT_HERDR_INNER:-}" ] && [ -n "${PI_SUBAGENT_HERDR_PANE:-}" ]; then
            herdr_owned_pane=$PI_SUBAGENT_HERDR_PANE
        fi
        unset PI_SUBAGENT_HERDR_PANE
        [ "$#" -eq 3 ] || exit 2
        run_turn "$1" "$2" "$3"
        ;;
    *) usage ;;
esac

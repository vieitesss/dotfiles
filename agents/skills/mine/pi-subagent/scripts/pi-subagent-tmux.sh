#!/bin/sh
# pi-subagent-tmux.sh — tmux-only watch-pane operations for pi-subagent.sh.
#
# Watcher boundary: every tmux command the helper needs lives here, invoked
# as a subprocess (never sourced). This CLI shape — not a sourced library —
# is the seam a future skill-level routing decision would use to add another
# watcher backend beside tmux (for example using-herdr). That routing choice
# belongs to the caller; do not grow this file into a plugin framework, and
# never create dedicated sessions here: outside a live supervisor session
# there is nothing to watch in.
#
# Usage:
#   pi-subagent-tmux.sh detect
#   pi-subagent-tmux.sh launch WINDOW TITLE CWD -- CMD
#   pi-subagent-tmux.sh cleanup WINDOW
#
# detect prints "session=<name>" and "session_id=<id>" (exit 0) when tmux is
# on PATH and $TMUX resolves to a live current session; otherwise it prints
# "reason=<slug>" plus a human notice and exits 1. A set-but-stale $TMUX
# (server gone) counts as not-inside-tmux, never as a hard error.
#
# launch starts CMD in a fresh pane of the helper-owned WINDOW, prints
# "pane=<id>", "pid=<pid>" and "session=<name>" on separate lines, and exits
# 0 only once the pane is observable. remain-on-exit is enabled on the
# window before the child starts, so even an instantly-failing child keeps
# its pane. Any setup failure exits nonzero having started nothing
# observable: no pane, no child, no fallback. WINDOW reuse is limited to the
# one window this helper marked (@pi-subagent-watch); an unmarked same-name
# window (legacy) or duplicate same-name windows are refused outright.
#
# cleanup sweeps finished panes in WINDOW but keeps one completed pane as an
# anchor when nothing is still running. It is lenient by design (exit 0) so
# list/status paths never fail on watch housekeeping.
set -u
umask 077

WATCH_OPT=@pi-subagent-watch
PLACEHOLDER_SECS=300
LOCK_WAIT_TENTHS=100

die() {
    printf 'error: pi-subagent-tmux: %s\n' "$*" >&2
    exit 2
}

usage() {
    cat >&2 <<'EOF'
usage:
  pi-subagent-tmux.sh detect
  pi-subagent-tmux.sh launch WINDOW TITLE CWD -- CMD
  pi-subagent-tmux.sh cleanup WINDOW
EOF
    exit 2
}

detect_session() {
    # Sets session/session_id, or reason on failure. Returns 0 on success.
    session=; session_id=; reason=
    command -v tmux >/dev/null 2>&1 || {
        reason=tmux-not-installed
        printf 'notice: tmux not found; subagent runs headless\n' >&2
        return 1
    }
    info=
    if [ -n "${TMUX:-}" ]; then
        if [ -n "${TMUX_PANE:-}" ]; then
            info=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name} #{session_id}' 2>/dev/null) || info=
        fi
        if [ -z "$info" ]; then
            info=$(tmux display-message -p '#{session_name} #{session_id}' 2>/dev/null) || info=
        fi
    fi
    # Session ids look like $N (no spaces); the name is everything before it.
    session=${info% *}
    session_id=${info##* }
    if [ -z "$info" ] || [ -z "$session" ] || [ -z "$session_id" ]; then
        session=; session_id=
        reason=not-inside-tmux
        printf 'notice: not inside a live tmux session; subagent runs headless\n' >&2
        return 1
    fi
    return 0
}

cmd_detect() {
    [ "$#" -eq 0 ] || usage
    if detect_session; then
        printf 'session=%s\nsession_id=%s\n' "$session" "$session_id"
        return 0
    fi
    printf 'reason=%s\n' "$reason"
    return 1
}

# Portable per-server/per-session lock (mkdir-based: no flock on macOS).
# The key folds in the tmux socket path so private test servers never share
# a lock with each other or the user's server. A recycled pid can read as a
# live holder; the wait is bounded and then fails explicitly.
lock_key() {
    sock=${TMUX%%,*}
    [ -n "$sock" ] || sock=notmux
    key=$(printf '%s|%s' "$sock" "$1" | tr -c 'A-Za-z0-9' '_')
    printf '%s/pi-subagent-tmux-%s.lock\n' "${TMPDIR:-/tmp}" "$key"
}

lock_acquire() {
    lock_dir=$(lock_key "$1") || return 1
    lock_held=
    tries=0
    while [ "$tries" -lt "$LOCK_WAIT_TENTHS" ]; do
        if mkdir "$lock_dir" 2>/dev/null; then
            printf '%s\n' "$$" > "$lock_dir/pid"
            lock_held=1
            return 0
        fi
        holder=$(cat "$lock_dir/pid" 2>/dev/null) || holder=
        if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
            tries=$((tries + 1))
            sleep 0.1
        else
            rm -rf "$lock_dir" # absent, corrupt, or dead holder: reclaim
        fi
    done
    lock_dir=
    return 1
}

lock_release() {
    [ -n "${lock_held:-}" ] || return 0
    lock_held=
    [ -n "${lock_dir:-}" ] && rm -rf "$lock_dir"
    lock_dir=
}

install_guard() {
    # Backstop: never leave the lock held or a placeholder pane behind.
    # shellcheck disable=SC2154 # code is assigned by the trap itself at fire time
    trap 'code=$?; [ -n "${orphan_pane:-}" ] && tmux kill-pane -t "$orphan_pane" >/dev/null 2>&1; orphan_pane=; lock_release; exit $code' EXIT HUP INT TERM
}

resolve_owned() {
    # Sets win to the helper-owned window id, or empty when WINDOW is
    # absent. Returns 1 (message on stderr) on legacy-unmarked or duplicate
    # exact-name matches — never commandeer those — and 2 when the session
    # itself cannot be listed.
    r_session=$1; r_window=$2
    win=
    list=$(tmux list-windows -t "$r_session" -F '#{window_id} #{window_name}' 2>/dev/null) || {
        printf 'error: pi-subagent-tmux: cannot list windows in tmux session %s\n' "$r_session" >&2
        return 2
    }
    matches=
    while IFS= read -r line; do
        id=${line%% *}
        name=${line#* }
        [ -n "$id" ] && [ "$name" = "$r_window" ] && matches="$matches $id"
    done <<EOF
$list
EOF
    # shellcheck disable=SC2086 # word-splitting window ids on purpose
    set -- $matches
    case $# in
        0) return 0 ;;
        1) win=$1 ;;
        *)
            printf 'error: pi-subagent-tmux: %d windows named %s in session %s; refusing to guess\n' "$#" "$r_window" "$r_session" >&2
            return 1
            ;;
    esac
    mark=$(tmux show-options -w -t "$win" "$WATCH_OPT" 2>/dev/null) || mark=
    [ "${mark##* }" = 1 ] || {
        printf 'error: pi-subagent-tmux: window %s in session %s is not helper-owned (legacy unmarked %s window); refusing to reuse it\n' "$win" "$r_session" "$r_window" >&2
        return 1
    }
    return 0
}

sweep_win() {
    # Kill finished panes in $1, except $2 (just launched) and — when
    # nothing is still running — one retained completed pane as anchor.
    # Only an explicit dead=1 mark authorizes a kill; anything else,
    # including unparsable lines, is left alone.
    s_win=$1; s_keep=${2:-}
    panes=$(tmux list-panes -t "$s_win" -F '#{pane_id}:#{pane_dead}' 2>/dev/null) || return 0
    dead=; live=0
    # shellcheck disable=SC2086 # word-splitting pane records on purpose
    for p in $panes; do
        id=${p%%:*}; flag=${p##*:}
        if [ "$flag" = 0 ]; then
            live=$((live + 1))
        elif [ "$flag" = 1 ] && [ -n "$id" ] && [ "$id" != "$s_keep" ]; then
            dead="${dead:+$dead }$id"
        fi
    done
    if [ "$live" -eq 0 ]; then
        case $dead in
            *' '*) dead=${dead% *} ;; # several finished, none live: keep the last
            *) return 0 ;; # zero or one finished pane: nothing to sweep
        esac
    fi
    # shellcheck disable=SC2086 # word-splitting pane ids on purpose
    for id in $dead; do tmux kill-pane -t "$id" >/dev/null 2>&1 || :; done
    return 0
}

create_win() {
    # Brand-new WINDOW ($2) in session $1 running CMD ($4, cwd $3): start a
    # placeholder first so remain-on-exit and the ownership mark land before
    # the child exists, then respawn the pane into the real command (which
    # inherits the pane cwd and the forwarded environment). Sets win/pane.
    # On failure nothing observable is left behind: the placeholder dies
    # with the guard trap, and respawn/pid failures kill the pane outright.
    c_session=$1; c_window=$2; c_cwd=$3; c_cmd=$4
    set --
    [ -n "${PI_SUBAGENT_PI:-}" ] && set -- "$@" -e "PI_SUBAGENT_PI=$PI_SUBAGENT_PI"
    [ -n "${PI_SUBAGENT_INTERCOM_EXTENSION:-}" ] && set -- "$@" -e "PI_SUBAGENT_INTERCOM_EXTENSION=$PI_SUBAGENT_INTERCOM_EXTENSION"
    info=$(tmux new-window -d "$@" -P -F '#{pane_id} #{pane_pid} #{window_id}' \
        -t "$c_session:" -n "$c_window" -c "$c_cwd" "sleep $PLACEHOLDER_SECS") || {
        printf 'error: pi-subagent-tmux: cannot create window %s in session %s\n' "$c_window" "$c_session" >&2
        return 1
    }
    pane=${info%% *}; rest=${info#* }; pid=${rest% *}; win=${rest##* }
    [ -n "$pane" ] && [ -n "$pid" ] && [ -n "$win" ] && [ "$pane" != "$info" ] || {
        printf 'error: pi-subagent-tmux: cannot parse new-window result\n' >&2
        return 1
    }
    orphan_pane=$pane
    tmux set-option -w -t "$win" remain-on-exit on || {
        printf 'error: pi-subagent-tmux: cannot set remain-on-exit on %s\n' "$win" >&2
        return 1
    }
    tmux set-option -w -t "$win" "$WATCH_OPT" 1 || {
        printf 'error: pi-subagent-tmux: cannot mark window %s as helper-owned\n' "$win" >&2
        return 1
    }
    tmux respawn-pane "$@" -k -t "$pane" "$c_cmd" || {
        printf 'error: pi-subagent-tmux: cannot start the subagent command in %s\n' "$pane" >&2
        return 1
    }
    orphan_pane=
    pid=
    tries=0
    while [ "$tries" -lt 20 ]; do
        pid=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null) || pid=
        [ -n "$pid" ] && break
        tries=$((tries + 1))
        sleep 0.1
    done
    [ -n "$pid" ] || {
        printf 'error: pi-subagent-tmux: pane %s vanished right after launch\n' "$pane" >&2
        tmux kill-pane -t "$pane" >/dev/null 2>&1 || :
        return 1
    }
    return 0
}

split_into() {
    # Split window $1 for CMD ($3, cwd $2): retention first so a fast child
    # cannot outrun it, then create. The child starts with the split, so no
    # placeholder is needed here. Sets pane/pid.
    s_win=$1; s_cwd=$2; s_cmd=$3
    tmux set-option -w -t "$s_win" remain-on-exit on || {
        printf 'error: pi-subagent-tmux: cannot set remain-on-exit on %s\n' "$s_win" >&2
        return 1
    }
    set --
    [ -n "${PI_SUBAGENT_PI:-}" ] && set -- "$@" -e "PI_SUBAGENT_PI=$PI_SUBAGENT_PI"
    [ -n "${PI_SUBAGENT_INTERCOM_EXTENSION:-}" ] && set -- "$@" -e "PI_SUBAGENT_INTERCOM_EXTENSION=$PI_SUBAGENT_INTERCOM_EXTENSION"
    info=$(tmux split-window "$@" -P -F '#{pane_id} #{pane_pid}' \
        -t "$s_win" -c "$s_cwd" "$s_cmd") || return 1
    pane=${info%% *}; pid=${info#* }
    [ -n "$pane" ] && [ -n "$pid" ] && [ "$pane" != "$info" ] || return 1
    return 0
}

target_alive() {
    tmux list-windows -t "$1" -F '#{window_id}' 2>/dev/null | grep -Fxq "$2"
}

cmd_launch() {
    [ "$#" -ge 4 ] || usage
    l_window=$1; l_title=$2; l_cwd=$3; shift 3
    [ "${1:-}" = -- ] || usage
    shift
    [ "$#" -eq 1 ] || usage
    l_cmd=$1
    detect_session || { printf 'reason=%s\n' "$reason"; return 1; }
    lock_acquire "$session_id" || die "timed out waiting for the watch lock in session $session"
    install_guard
    if ! resolve_owned "$session" "$l_window"; then
        die "cannot reuse the watch window in session $session"
    fi
    if [ -n "$win" ]; then
        if split_into "$win" "$l_cwd" "$l_cmd"; then
            tmux select-layout -t "$win" tiled >/dev/null 2>&1 || :
        elif target_alive "$session" "$win"; then
            die "cannot split a pane into window $win in session $session"
        else
            # The target vanished under us: recreate once and run the turn
            # there instead of splitting. Any other error stays explicit.
            create_win "$session" "$l_window" "$l_cwd" "$l_cmd" || die "cannot recreate the watch window in session $session"
        fi
    else
        create_win "$session" "$l_window" "$l_cwd" "$l_cmd" || die "cannot create the watch window in session $session"
    fi
    sweep_win "$win" "$pane"
    tmux select-pane -t "$pane" -T "$l_title" >/dev/null 2>&1 || :
    printf 'pane=%s\npid=%s\nsession=%s\n' "$pane" "$pid" "$session"
    lock_release
    return 0
}

cmd_cleanup() {
    [ "$#" -eq 1 ] || usage
    c_window=$1
    detect_session >/dev/null 2>&1 || return 0
    lock_acquire "$session_id" >/dev/null 2>&1 || return 0
    install_guard
    err_file=$(mktemp "${TMPDIR:-/tmp}/pi-subagent-tmux-err.XXXXXX" 2>/dev/null) || {
        lock_release
        return 0
    }
    if resolve_owned "$session" "$c_window" 2>"$err_file"; then
        rm -f "$err_file"
        [ -n "$win" ] && sweep_win "$win"
    else
        # Ownership conflict or a session that vanished mid-cleanup: say so,
        # but never fail the caller's list/status over housekeeping.
        cat "$err_file" >&2
        rm -f "$err_file"
    fi
    lock_release
    return 0
}

command=${1:-}
[ "$#" -gt 0 ] && shift
case $command in
    detect) cmd_detect "$@" ;;
    launch) cmd_launch "$@" ;;
    cleanup) cmd_cleanup "$@" ;;
    *) usage ;;
esac

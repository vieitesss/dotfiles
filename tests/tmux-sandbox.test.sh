#!/usr/bin/env bash
# Fixture test for scripts/tmux-sandbox.
#
# Usage: ./tests/tmux-sandbox.test.sh
#
# A throwaway "sentinel" server stands in for the live one: a command run
# through the sandbox must be able to start and kill a server of its own
# without touching any other server.

set -eu

repo_root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)
sandbox_src="$repo_root/scripts/tmux-sandbox"
tmux_bin=$(command -v tmux) || {
    printf 'skip - tmux not installed\n'
    exit 0
}

# A server is addressed by TMUX, so never inherit one; keep any stray
# default-socket call inside this test's own directory.
unset TMUX TMUX_PANE
# tmux sockets live under a ~104 character path limit, hence /tmp rather than
# the longer TMPDIR.
work=$(mktemp -d /tmp/tmux-sandbox-test.XXXXXX)
export TMUX_TMPDIR="$work/tmux-tmpdir"
mkdir -p "$TMUX_TMPDIR"

sentinel_sock="$work/sentinel.sock"
out="$work/out"
fixture_home="$work/home"
theme="$fixture_home/.tmux/plugins/gruber-darker-tmux-theme"
mkdir -p "$out" "$theme"

# Pre-seeded plugins keep tmux/.tmux.conf from cloning anything from the network.
printf 'set -g @theme fixture\n' > "$theme/gruber-darker-tmux-theme.tmux"
printf 'set -g @theme fixture\n' > "$theme/gruber-lighter-tmux-theme.tmux"

cleanup() {
    "$tmux_bin" -S "$sentinel_sock" kill-server 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

failures=0
checks=0

fail() {
    failures=$((failures + 1))
    printf 'FAIL: %s\n' "$1"
}

expect_eq() { # expected actual message
    checks=$((checks + 1))
    [ "$2" = "$1" ] || fail "$3: expected '$1', got '$2'"
}

expect_contains() { # file needle message
    checks=$((checks + 1))
    grep -q -- "$2" "$1" || fail "$3: '$2' not found in $1 ($(cat "$1" 2>/dev/null))"
}

expect_missing() { # path message
    checks=$((checks + 1))
    [ ! -e "$1" ] || fail "$2: $1 still exists"
}

# --- the sentinel server stands in for the live one --------------------------

"$tmux_bin" -S "$sentinel_sock" -f /dev/null new-session -d -s sentinel
"$tmux_bin" -S "$sentinel_sock" set-option -g @sentinel keep-me
sentinel_pid=$("$tmux_bin" -S "$sentinel_sock" display-message -p '#{pid}')
# The whole global config, so a stray reload of tmux/.tmux.conf would show.
"$tmux_bin" -S "$sentinel_sock" show-options -g > "$out/sentinel-before"

# --- a command inside the sandbox starts a server, reloads the config, and
#     runs a bare kill-server ------------------------------------------------

export REPO="$repo_root" OUT="$out"
set +e
# shellcheck disable=SC2016  # expanded inside the sandbox, not here
TMUX="$sentinel_sock,$sentinel_pid,0" HOME="$fixture_home" \
    "$sandbox_src" bash -c '
        set -eu
        printf "%s\n" "${TMUX:-}" > "$OUT/tmux"
        printf "%s\n" "$TMUX_SOCK" > "$OUT/sock"
        tmux -f /dev/null new-session -d -s sandbox
        if [ ! -S "$TMUX_SOCK" ]; then printf leaked > "$OUT/socket-unused"; fi
        tmux source-file "$REPO/tmux/.tmux.conf"
        tmux ls > "$OUT/before"
        tmux kill-server
        if tmux ls > "$OUT/after" 2>&1; then :; else printf dead > "$OUT/killed"; fi
    '
status=$?
set -e

expect_eq 0 "$status" 'runner exit status'
expect_eq '' "$(cat "$out/tmux")" 'sandbox leaves no inherited TMUX in the environment'
expect_missing "$out/socket-unused" 'bare tmux talks to TMUX_SOCK'
expect_contains "$out/before" 'sandbox:' 'the sandboxed command had a server of its own'
expect_contains "$out/killed" 'dead' 'bare kill-server reached the sandboxed command server'

sock=$(cat "$out/sock")
checks=$((checks + 1))
if [ -z "$sock" ] || [ "$sock" = "$sentinel_sock" ]; then
    fail "TMUX_SOCK must be a private socket, got '$sock'"
fi
expect_missing "$(dirname "$sock")" 'the runner removes its temporary directory'

# --- the sentinel is untouched ----------------------------------------------

checks=$((checks + 1))
"$tmux_bin" -S "$sentinel_sock" list-sessions >/dev/null 2>&1 ||
    fail 'the sentinel server is still running'
expect_eq 'keep-me' "$("$tmux_bin" -S "$sentinel_sock" show-options -gv @sentinel)" \
    'the sentinel server options are unchanged'
"$tmux_bin" -S "$sentinel_sock" show-options -g > "$out/sentinel-after"
checks=$((checks + 1))
cmp -s "$out/sentinel-before" "$out/sentinel-after" ||
    fail 'the sentinel server global config is unchanged'

if [ "$failures" -gt 0 ]; then
    printf '\n%s of %s checks failed\n' "$failures" "$checks"
    exit 1
fi

printf 'ok - %s checks\n' "$checks"

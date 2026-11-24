#!/bin/sh
# Test the native project picker without touching live Rex sessions.
set -eu

if ! command -v rex >/dev/null 2>&1; then
    printf 'skip: %s (rex is not installed)\n' "$0"
    exit 0
fi

repo_root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)

tmp=$(mktemp -d /tmp/rex-sessions-test.XXXXXX)
tmp=$(unset CDPATH; cd -- "$tmp" && pwd -P)
endpoint="unix://$tmp/server.sock"
cleanup() {
    rex --autostart=false -S "$endpoint" server stop >/dev/null 2>&1 || :
    rm -rf "$tmp"
}
trap cleanup EXIT

# The unit cases keep the project cache in a throwaway database.
out=$(REX_CONFIG_DIR="$repo_root/rex" REX_DB="$tmp/unit-db.json" \
    rex 'do' "$repo_root/tests/rex-sessions.test.lua") || {
    printf 'FAIL: %s\n' "$out" >&2
    exit 1
}
[ "$out" = ok ] || {
    printf 'FAIL: %s\n' "$out" >&2
    exit 1
}
mkdir -p "$tmp/home/personal/demo.app" "$tmp/home/work" "$tmp/home/.config" "$tmp/home/opt"

rex -S "$endpoint" server start --config "$repo_root/tests/rex-sessions.config.lua" \
    --state-dir "$tmp/state" --restore=false --env "REX_CONFIG_DIR=$repo_root/rex" \
    --env "HOME=$tmp/home" --env "REX_BIN_DIR=$(dirname "$(command -v rex)")" --env 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' \
    >/dev/null
# A real config action must reach the server's prompt dispatcher. Without an
# app connected it returns no_client; script actions return unsupported instead.
for scope in local remote; do
    set -- 'do' rex_sessions
    if [ "$scope" = remote ]; then
        # Exercise the actual remote action context, not a Lua mock. This
        # caller cannot proxy the foreign host, but local catalog access and
        # the native prompt must still work. Remote discovery failure is soft.
        set -- api call client.action \
            '{"action":"rex_sessions","server":"remote","servers":[{"name":"remote","id":"unreachable"}]}'
    fi
    if REX_SESSION='' REX_BLOCK='' REX_CLIENT='' rex --autostart=false -S "$endpoint" \
        --timeout 20s "$@" >"$tmp/stdout" 2>"$tmp/stderr"; then
        printf 'FAIL: expected no_client in %s context without a connected app\n' "$scope" >&2
        exit 1
    fi
    if ! grep -q 'sessions: no_client' "$tmp/stderr"; then
        printf 'FAIL: native prompt dispatcher was not reached in %s context\n' "$scope" >&2
        cat "$tmp/stderr" >&2
        exit 1
    fi
done

# Create from a remote context, then reuse from both contexts. The actual
# local server must own the target, with no picker tab among its windows.
previous=
for scope in remote local remote; do
    args='{"action":"rex_sessions_select_test"}'
    if [ "$scope" = remote ]; then
        args='{"action":"rex_sessions_select_test","server":"remote","servers":[{"name":"remote","id":"unreachable"}]}'
    fi
    REX_SESSION='' REX_BLOCK='' REX_CLIENT='' rex --autostart=false -S "$endpoint" \
        api call client.action "$args" >"$tmp/selection"
    selected=$(REX_SESSION='' REX_BLOCK='' REX_CLIENT='' REX_TEST_PROJECT="$tmp/home/personal/demo.app" \
        rex --autostart=false -S "$endpoint" 'do' -e '
local response = rex.json.decode(io.read("*a"))
assert(#response.client_actions == 1, "one deferred selection")
local action = response.client_actions[1]
assert(action.action == "session.select", "selection action")
local sessions = rex.call("session.list").sessions
assert(#sessions == 1, "exactly one local session")
local session = sessions[1]
assert(session.label == "personal_demo_app", "local session label")
assert(action.args.session_id == session.session_id, "local selection target")
assert(rex.call("session.attach", { session_id = session.session_id }))
local view = rex.session.view{ session_id = session.session_id }
assert(#view.windows == 1, "no picker tab")
assert(action.args.window_id == view.active_window_id, "selected window")
local directory = rex.block.call("com.superlogical.terminal", "list_dir", {
  session_id = session.session_id, block_id = view.windows[1].focused_block_id, path = ".",
})
assert(directory.path == os.getenv("REX_TEST_PROJECT"),
  "local project cwd: " .. tostring(directory.path) .. "; expected " .. os.getenv("REX_TEST_PROJECT"))
print(session.session_id)
' <"$tmp/selection")
    if [ -n "$previous" ] && [ "$selected" != "$previous" ]; then
        printf 'FAIL: %s context did not reuse the local session\n' "$scope" >&2
        exit 1
    fi
    previous=$selected
done
printf 'ok: %s\n' "$0"

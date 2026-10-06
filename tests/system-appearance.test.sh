#!/bin/sh
# Fixture test for scripts/system-appearance and its plugins in
# system-appearance/. Run: sh tests/system-appearance.test.sh
#
# The plugins otherwise mutate the real machine (wallpaper, appearance, remote
# hosts). The test runs against a throwaway HOME whose .local/bin is first on
# PATH, so every side-effecting command (ssh, osascript, open, pgrep, pkill,
# tmux, herdr, sleep) is replaced by a stub; ssh also records the args and
# stdin it was handed. Each case gets its own copy of the plugin directory.
set -eu

if [ "$(uname -s)" != Darwin ]; then
    printf 'skip: %s (system-appearance is macOS only)\n' "$0"
    exit 0
fi

repo_root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
script="$repo_root/scripts/system-appearance"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

home="$tmp/home"
dir="$tmp/system-appearance"
record="$tmp/ssh.log"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

write_fake() {
    name=$1
    cat > "$home/.local/bin/$name"
    chmod +x "$home/.local/bin/$name"
}

# Rebuild the throwaway machine and plugin directory before each case.
reset() {
    rm -rf "$home" "$dir" "$record" "$tmp/stdout" "$tmp/stderr" "$tmp/added.log"
    mkdir -p "$home/.local/bin" "$home/Pictures" "$home/.local/state"
    cp -R "$repo_root/system-appearance" "$dir"
    : > "$home/Pictures/astronaut_umbraline.png"
    : > "$home/Pictures/astronaut_light.png"
    : > "$record"

    write_fake ssh <<'SH'
#!/bin/sh
{
    printf 'ARGS:'
    for arg in "$@"; do printf ' %s' "$arg"; done
    printf '\nSTDIN-BEGIN\n'
    cat
    printf '\nSTDIN-END\n'
} >> "$SSH_RECORD"
SH
    write_fake osascript <<'SH'
#!/bin/sh
printf 'false\n'
SH
    for name in open pgrep pkill tmux herdr sleep; do
        printf '#!/bin/sh\nexit 0\n' | write_fake "$name"
    done
}

run() {
    set +e
    HOME="$home" SYSTEM_APPEARANCE_DIR="$dir" SSH_RECORD="$record" \
        sh "$script" "$@" >"$tmp/stdout" 2>"$tmp/stderr"
    status=$?
    set -e
}

expect_status() {
    [ "$status" -eq "$1" ] || fail "expected exit $1, got $status (stderr: $(cat "$tmp/stderr"))"
}

expect_stdout() {
    grep -qF -- "$1" "$tmp/stdout" || fail "stdout missing: $1 (got: $(cat "$tmp/stdout"))"
}

expect_stderr() {
    grep -qF -- "$1" "$tmp/stderr" || fail "stderr missing: $1 (got: $(cat "$tmp/stderr"))"
}

count_matches() {
    grep -c -- "$2" "$1" 2>/dev/null || true
}

expect_ssh_calls() {
    [ "$(count_matches "$record" '^ARGS:')" -eq "$1" ] ||
        fail "expected $1 ssh call(s) (got: $(cat "$record"))"
}

expect_record() {
    grep -q -- "$1" "$record" || fail "ssh record missing: $1 (got: $(cat "$record"))"
}

# Add a plugin that records the mode it was called with.
add_recording_plugin() {
    cat > "$dir/plugins/$1" <<'SH'
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$1" >> "$ADDED_LOG"
SH
    chmod +x "$dir/plugins/$1"
}

# The shipped hosts file targets vieitesrpi alone, with one ssh call that
# carries every remote/ script and the mode.
case_default_hosts() {
    reset

    run dark

    expect_status 0
    expect_ssh_calls 1
    expect_record 'ARGS: -o BatchMode=yes -o ConnectTimeout=3 vieitesrpi sh -s dark'
    expect_record 'SYSTEM_APPEARANCE'
    expect_record 'nexo/config.toml'
    expect_stdout 'System appearance: dark'
}

# Hosts are configurable: one per line, with comments and blank lines.
case_configured_hosts() {
    reset
    cat > "$dir/hosts" <<'HOSTS'
# primary
alpha

beta # backup
HOSTS

    run light

    expect_status 0
    expect_ssh_calls 2
    expect_record 'ARGS:.* alpha sh -s light'
    expect_record 'ARGS:.* beta sh -s light'
}

# Without a hosts file the remote plugin warns and the switch still succeeds.
case_missing_hosts() {
    reset
    rm "$dir/hosts"

    run dark

    expect_status 0
    expect_ssh_calls 0
    expect_stderr 'no remote hosts file'
}

# Deleting a plugin file drops that element: no remote plugin, no ssh; no
# wallpaper plugin, so missing pictures no longer matter.
case_removed_plugins() {
    reset
    rm "$dir/plugins/"*-remote "$dir/plugins/"*-wallpaper "$home/Pictures/"*

    run dark

    expect_status 0
    expect_ssh_calls 0
}

# Adding an executable file adds an element; it receives the mode and runs in
# name order. A non-executable file is ignored.
case_added_plugin() {
    reset
    add_recording_plugin 00-first
    add_recording_plugin 99-last
    printf '#!/bin/sh\nexit 1\n' > "$dir/plugins/55-disabled"

    ADDED_LOG="$tmp/added.log"
    export ADDED_LOG
    run light

    expect_status 0
    [ "$(cat "$tmp/added.log")" = "00-first light
99-last light" ] || fail "added plugins ran wrong: $(cat "$tmp/added.log")"
}

# A failing plugin is reported by name; the rest still run and the runner
# exits nonzero so the shortcut can alert.
case_failing_plugin() {
    reset
    printf '#!/bin/sh\nexit 3\n' > "$dir/plugins/15-broken"
    chmod +x "$dir/plugins/15-broken"

    run dark

    expect_status 1
    expect_stderr 'plugin 15-broken failed (exit 3)'
    expect_ssh_calls 1
}

# A missing plugin directory fails loudly before anything changes.
case_missing_plugins_dir() {
    reset
    rm -r "$dir/plugins"

    run dark

    expect_status 1
    expect_stderr "plugin directory not found: $dir/plugins"
}

case_default_hosts
case_configured_hosts
case_missing_hosts
case_removed_plugins
case_added_plugin
case_failing_plugin
case_missing_plugins_dir
printf 'ok: %s\n' "$0"

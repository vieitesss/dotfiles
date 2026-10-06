#!/bin/sh
# Fixture test for scripts/system-appearance. Run: sh scripts/system-appearance.test.sh
#
# The script under test is macOS-only and otherwise mutates the real machine
# (wallpaper, appearance, remote hosts). The test runs it against a throwaway
# HOME whose .local/bin is first on PATH, so every side-effecting command
# (ssh, osascript, open, pgrep, pkill, tmux, herdr, sleep) is replaced by a
# stub; ssh also records the args and stdin it was handed.
set -eu

repo_root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
script="$repo_root/scripts/system-appearance"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

home="$tmp/home"
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

# Rebuild the throwaway machine before each case.
reset() {
    rm -rf "$home" "$record" "$tmp/stdout" "$tmp/stderr"
    mkdir -p "$home/.local/bin" "$home/.config/nexo" "$home/Pictures" "$home/.local/state"
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
    write_fake open <<'SH'
#!/bin/sh
exit 0
SH
    write_fake pgrep <<'SH'
#!/bin/sh
exit 0
SH
    write_fake pkill <<'SH'
#!/bin/sh
exit 0
SH
    write_fake tmux <<'SH'
#!/bin/sh
exit 0
SH
    write_fake herdr <<'SH'
#!/bin/sh
exit 0
SH
    write_fake sleep <<'SH'
#!/bin/sh
exit 0
SH
}

run() {
    set +e
    HOME="$home" SSH_RECORD="$record" sh "$script" "$@" >"$tmp/stdout" 2>"$tmp/stderr"
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

expect_record() {
    grep -q -- "$1" "$record" || fail "ssh record missing: $1 (got: $(cat "$record"))"
}

# The per-host remote command: every configured host gets one ssh call that
# pins nexo's theme and reloads tmux in the target mode.
case_valid_config() {
    reset
    cat > "$home/.config/nexo/config.toml" <<'TOML'
[remote]
machines = ["alpha", "beta"]
TOML

    run dark

    expect_status 0
    [ "$(count_matches "$record" '^ARGS:')" -eq 2 ] ||
        fail "expected one ssh call per host (got: $(cat "$record"))"
    expect_record 'ARGS:.* -o BatchMode=yes -o ConnectTimeout=3 alpha sh -s dark'
    expect_record 'ARGS:.* -o BatchMode=yes -o ConnectTimeout=3 beta sh -s dark'
    expect_record 'SYSTEM_APPEARANCE'
    expect_record 'nexo/config.toml'
    expect_stdout 'System appearance: dark'
}

# A missing nexo config must not be swallowed: the script reports it and fails
# before it touches any host.
case_missing_config() {
    reset

    run dark

    expect_status 1
    expect_stderr 'nexo config not found'
    expect_stderr "$home/.config/nexo/config.toml"
    [ "$(count_matches "$record" '^ARGS:')" -eq 0 ] || fail 'missing config still contacted a host'
}

# A multi-line machines array (with a comment and a following section) parses
# the same way.
case_multiline_hosts() {
    reset
    cat > "$home/.config/nexo/config.toml" <<'TOML'
[remote]
machines = [
    "alpha", # primary
    "beta",
]

[remote.backends]
alpha = "tmux"
TOML

    run light

    expect_status 0
    [ "$(count_matches "$record" '^ARGS:')" -eq 2 ] ||
        fail "expected one ssh call per host (got: $(cat "$record"))"
    expect_record 'ARGS:.* alpha sh -s light'
    expect_record 'ARGS:.* beta sh -s light'
}

# A malformed [remote] machines value must surface the parse error instead of
# silently looping over zero hosts.
case_malformed_config() {
    reset
    cat > "$home/.config/nexo/config.toml" <<'TOML'
[remote]
machines = "alpha"
TOML

    run dark

    expect_status 1
    expect_stderr 'malformed nexo config'
    [ "$(count_matches "$record" '^ARGS:')" -eq 0 ] || fail 'malformed config still contacted a host'
}

# An array left open at the end of the file is malformed too.
case_unclosed_array() {
    reset
    cat > "$home/.config/nexo/config.toml" <<'TOML'
[remote]
machines = [
    "alpha",
TOML

    run dark

    expect_status 1
    expect_stderr 'malformed nexo config'
    expect_stderr 'array is not closed'
}

# Zero configured hosts is not an error: warn once and keep the local switch.
case_no_hosts() {
    reset
    cat > "$home/.config/nexo/config.toml" <<'TOML'
[remote]
ssh-config = ""
TOML

    run dark

    expect_status 0
    [ "$(count_matches "$tmp/stderr" 'no remote hosts configured')" -eq 1 ] ||
        fail "expected one no-hosts warning (got: $(cat "$tmp/stderr"))"
    [ "$(count_matches "$record" '^ARGS:')" -eq 0 ] || fail 'no-hosts config still contacted a host'
}

case_valid_config
case_multiline_hosts
case_missing_config
case_malformed_config
case_unclosed_array
case_no_hosts
printf 'ok: %s\n' "$0"

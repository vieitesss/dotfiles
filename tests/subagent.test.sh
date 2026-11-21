#!/usr/bin/env bash
# Fixture tests for agents/skills/subagents/scripts/subagent.
#
# Usage: ./tests/subagent.test.sh
#
# Every case runs the launcher in a throwaway git repo with a throwaway HOME,
# and stubs rex, recado and pi on PATH: no window opens and no Subagent starts.

set -eu

repo_root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)
subagent_src="$repo_root/agents/skills/subagents/scripts/subagent"

# macOS's /bin/bash is 3.2, the oldest shell the launcher must run on.
if [ -x /bin/bash ]; then
    subagent_bash=/bin/bash
else
    subagent_bash=bash
fi

failures=0
checks=0

# --- helpers ----------------------------------------------------------------

new_fixture() {
    fixture_tmp=$(CDPATH='' cd "$(mktemp -d "${TMPDIR:-/tmp}/subagent-test.XXXXXX")" && pwd -P)
    fixture_repo="$fixture_tmp/repo"
    fixture_home="$fixture_tmp/home"
    fixture_bin="$fixture_tmp/bin"
    fixture_log="$fixture_tmp/rex.log"
    fixture_prompt="$fixture_tmp/prompt.md"
    fixture_pi_log="$fixture_tmp/pi.log"
    fixture_agy_log="$fixture_tmp/agy.log"
    fixture_agy_prompt="$fixture_tmp/agy-prompt.md"
    fixture_agy_env="$fixture_tmp/agy-env"
    fixture_stderr="$fixture_tmp/stderr"
    fixture_process=

    mkdir -p "$fixture_repo" "$fixture_home" "$fixture_bin" "$fixture_tmp/tmp"

    git -C "$fixture_repo" init -q
    git -C "$fixture_repo" -c user.email=subagent@test -c user.name=subagent \
        commit -q --allow-empty -m fixture

    # Every skill the Stage table names, installed in the throwaway HOME.
    for skill in research tdd coding writing-for-agents zero-tech-debt retro review; do
        mkdir -p "$fixture_home/.agents/skills/$skill"
        printf -- '---\nname: %s\n---\n' "$skill" > "$fixture_home/.agents/skills/$skill/SKILL.md"
    done

    # rex stub: records arguments independently of their order, executes the
    # window's child command, hands back ids, and reports the block's process.
    cat > "$fixture_bin/rex" <<'STUB'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" >> "$REX_STUB_LOG"
[ "${1:-}" != --autostart=false ] || shift
case "$1 ${2:-}" in
    'window new')
        shift 2
        while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
        [ "$#" -gt 0 ] || exit 1
        shift
        "$@" >"$REX_STUB_LOG.child" 2>&1 || {
            cat "$REX_STUB_LOG.child" >&2
            exit 1
        }
        printf '{"window_id":"win-1","block_ids":["blk-1"]}\n'
        ;;
    'block call')
        printf '%s\n' "${REX_STUB_PROCESS:-{\"last_exit\":null}}"
        ;;
    'capture '*)
        printf 'simulated agent crash on startup\n'
        ;;
    *) exit 1 ;;
esac
STUB

    # Run the received shell command without login profiles, which could
    # replace PATH and accidentally resolve a real pi instead of the stub.
    cat > "$fixture_bin/shell" <<'STUB'
#!/usr/bin/env bash
set -eu
[ "${PATH%%:*}" = "$STUB_BIN" ] || exit 99
case $1 in
    -c | -lc) shift ;;
    *) exit 99 ;;
esac
exec /bin/bash -c "$@"
STUB

    # pi stub: record what the child delivers, not how it transports it.
    cat > "$fixture_bin/pi" <<'STUB'
#!/usr/bin/env bash
set -eu
[ "${PATH%%:*}" = "$STUB_BIN" ] || exit 99
while [ "$#" -gt 0 ]; do
    case $1 in
        --model | --thinking | --append-system-prompt)
            printf '%s=%s\n' "$1" "$2" >> "$PI_STUB_LOG"
            shift 2
            ;;
        --)
            shift
            [ "$#" -eq 1 ] || exit 1
            printf '%s\n' "$1" > "$PI_STUB_PROMPT"
            exit 0
            ;;
        *) exit 1 ;;
    esac
done
exit 1
STUB

    # agy stub: record what the child delivers, its environment, and whether
    # the prompt arrives as the value of -i.
    cat > "$fixture_bin/agy" <<'STUB'
#!/usr/bin/env bash
set -eu
[ "${PATH%%:*}" = "$STUB_BIN" ] || exit 99
prompt=
while [ "$#" -gt 0 ]; do
    case $1 in
        --model | --effort | --mode)
            printf '%s=%s\n' "$1" "$2" >> "$AGY_STUB_LOG"
            shift 2
            ;;
        -i)
            printf '%s\n' -i >> "$AGY_STUB_LOG"
            shift
            [ "$#" -eq 1 ] || exit 1
            prompt=$1
            shift
            ;;
        *) exit 1 ;;
    esac
done
[ -n "$prompt" ] || exit 1
printf '%s\n' "$prompt" > "$AGY_STUB_PROMPT"
for name in GIT_EDITOR GIT_SEQUENCE_EDITOR GIT_TERMINAL_PROMPT GIT_PAGER PAGER GH_PROMPT_DISABLED CI; do
    printf '%s=%s\n' "$name" "$(printenv "$name" || printf '<unset>')" >> "$AGY_STUB_ENV"
done
STUB

    # recado stub: whoami names the Manager; nothing is delivered.
    cat > "$fixture_bin/recado" <<'STUB'
#!/usr/bin/env bash
case $1 in
    whoami) printf 'recado://local/manager\n' ;;
esac
STUB

    chmod +x "$fixture_bin/rex" "$fixture_bin/recado" "$fixture_bin/pi" "$fixture_bin/agy" "$fixture_bin/shell"
}

run_subagent() { # run_subagent ARGS... < BRIEF
    set +e
    output=$(
        cd "$fixture_repo" || exit 1
        # Drop the variables the child must set itself, so a value inherited
        # from the caller cannot make the assertion pass.
        env -u CI -u GIT_EDITOR -u GIT_SEQUENCE_EDITOR -u GIT_TERMINAL_PROMPT \
            -u GIT_PAGER -u PAGER -u GH_PROMPT_DISABLED \
            HOME="$fixture_home" \
            PATH="$fixture_bin:$PATH" \
            STUB_BIN="$fixture_bin" \
            SHELL="$fixture_bin/shell" BASH_ENV=/dev/null ENV=/dev/null \
            TMPDIR="$fixture_tmp/tmp" \
            REX_SESSION=session:test \
            REX_STUB_LOG="$fixture_log" \
            PI_STUB_LOG="$fixture_pi_log" \
            PI_STUB_PROMPT="$fixture_prompt" \
            AGY_STUB_LOG="$fixture_agy_log" \
            AGY_STUB_PROMPT="$fixture_agy_prompt" \
            AGY_STUB_ENV="$fixture_agy_env" \
            REX_STUB_PROCESS="$fixture_process" \
            "$subagent_bash" "$subagent_src" "$@" 2>"$fixture_stderr"
    )
    status=$?
    set -e
    error=$(cat "$fixture_stderr")
}

fail() {
    failures=$((failures + 1))
    printf 'FAIL: %s\n' "$1"
}

expect_status() {
    checks=$((checks + 1))
    [ "$status" -eq "$1" ] || fail "expected exit $1, got $status; output:
$output
$error"
}

expect_nonzero() {
    checks=$((checks + 1))
    [ "$status" -ne 0 ] || fail "expected a non-zero exit; output:
$output"
}

expect_contains() {
    checks=$((checks + 1))
    case "$output" in
        *"$1"*) ;;
        *) fail "expected stdout to contain '$1'; got:
$output" ;;
    esac
}

expect_stderr_contains() {
    checks=$((checks + 1))
    case "$error" in
        *"$1"*) ;;
        *) fail "expected stderr to contain '$1'; got:
$error" ;;
    esac
}

expect_prompt_contains() {
    checks=$((checks + 1))
    if [ ! -f "$fixture_prompt" ]; then
        fail "no prompt file; rex was called with:
$(cat "$fixture_log" 2>/dev/null)"
        return
    fi
    case "$(cat "$fixture_prompt")" in
        *"$1"*) ;;
        *) fail "expected the prompt to contain '$1'; got:
$(cat "$fixture_prompt")" ;;
    esac
}

expect_rex_arg() {
    checks=$((checks + 1))
    grep -Fxq -- "$1" "$fixture_log" 2>/dev/null ||
        fail "expected rex to receive argument '$1'; got:
$(cat "$fixture_log" 2>/dev/null)"
}

expect_pi_option() {
    checks=$((checks + 1))
    grep -Fxq -- "$1=$2" "$fixture_pi_log" 2>/dev/null ||
        fail "expected pi to receive '$1' with '$2'; got:
$(cat "$fixture_pi_log" 2>/dev/null)"
}

expect_agy_option() {
    checks=$((checks + 1))
    grep -Fxq -- "$1=$2" "$fixture_agy_log" 2>/dev/null ||
        fail "expected agy to receive '$1' with '$2'; got:
$(cat "$fixture_agy_log" 2>/dev/null)"
}

expect_agy_flag() {
    checks=$((checks + 1))
    grep -Fxq -- "$1" "$fixture_agy_log" 2>/dev/null ||
        fail "expected agy to receive the flag '$1'; got:
$(cat "$fixture_agy_log" 2>/dev/null)"
}

expect_agy_env() {
    checks=$((checks + 1))
    grep -Fxq -- "$1=$2" "$fixture_agy_env" 2>/dev/null ||
        fail "expected the agent to run with $1=$2; got:
$(cat "$fixture_agy_env" 2>/dev/null)"
}

expect_agy_prompt_contains() {
    checks=$((checks + 1))
    if [ ! -f "$fixture_agy_prompt" ]; then
        fail "no agy prompt; rex was called with:
$(cat "$fixture_log" 2>/dev/null)"
        return
    fi
    case "$(cat "$fixture_agy_prompt")" in
        *"$1"*) ;;
        *) fail "expected the agy prompt to contain '$1'; got:
$(cat "$fixture_agy_prompt")" ;;
    esac
}

expect_no_rex_command() {
    checks=$((checks + 1))
    if [ -f "$fixture_log" ] && grep -Fxq window "$fixture_log"; then
        fail "expected no window to be opened; rex got:
$(cat "$fixture_log")"
    fi
}

# --- the prompt names the tag, the report and the Manager -------------------

new_fixture
run_subagent launch --stage build --item widget <<'BRIEF'
Add the widget.
BRIEF
expect_status 0
# The tag embeds the launcher's pid, so match around it.
checks=$((checks + 1))
case "$(cat "$fixture_prompt" 2>/dev/null)" in
    *"[subagent-build-"*" · widget · build]"*) ;;
    *) fail "the prompt does not carry [subagent-build-<pid> · widget · build]:
$(cat "$fixture_prompt" 2>/dev/null)" ;;
esac
expect_prompt_contains "$fixture_repo/.agents/reports/widget-build.md"
expect_prompt_contains "recado send recado://local/manager --kind complete"
expect_prompt_contains "recado ask recado://local/manager"
expect_prompt_contains "Add the widget."
expect_prompt_contains 'Use the read and edit tools for files (not python heredocs or bash cat).'
expect_prompt_contains 'in codemode, slice or filter outputs in JS so each call returns under ~20 KB without truncation.'
expect_prompt_contains 'The brief is your approved plan; commit your work on the branch.'
expect_contains "\"report\":\"$fixture_repo/.agents/reports/widget-build.md\""
expect_contains '"window":"win-1"'
expect_contains '"block":"blk-1"'
checks=$((checks + 1))
[ -d "$fixture_repo/.agents/reports" ] || fail "the report directory was not created"

rm -rf "$fixture_tmp"

# --- a missing skill fails before anything launches -------------------------

new_fixture
rm -rf "$fixture_home/.agents/skills/tdd"
run_subagent launch --stage build --item widget <<'BRIEF'
Add the widget.
BRIEF
expect_nonzero
expect_stderr_contains 'skills not installed'
expect_stderr_contains 'tdd'
expect_no_rex_command

rm -rf "$fixture_tmp"

# --- launch runs pi with the Stage's model and effort in a Rex window -------

new_fixture
run_subagent launch --stage refine --item widget <<'BRIEF'
Remove the legacy path.
BRIEF
expect_status 0
expect_rex_arg session:test
expect_rex_arg --focus=false
expect_rex_arg --keep-open
expect_rex_arg --shell=none
expect_pi_option --model github-copilot/gpt-6.2-sol
expect_pi_option --thinking high
expect_prompt_contains 'You run the Refine stage:'
expect_prompt_contains 'Remove the legacy path.'
expect_contains '"name":"subagent-refine-'

rm -rf "$fixture_tmp"

# --- the child runs the agent non-interactively ---------------------------

new_fixture
run_subagent launch --stage write --item widget <<'BRIEF'
Write the changelog.
BRIEF
expect_status 0
expect_agy_env GIT_EDITOR true
expect_agy_env GIT_SEQUENCE_EDITOR true
expect_agy_env GIT_TERMINAL_PROMPT 0
expect_agy_env GIT_PAGER cat
expect_agy_env PAGER cat
expect_agy_env GH_PROMPT_DISABLED 1
expect_agy_env CI '<unset>'

rm -rf "$fixture_tmp"

# --- a model id reaches agy, and the retro Stage carries its own skills ----

new_fixture
run_subagent launch --stage retro --item retro-2 --model agy/gemini-4-neon-high <<'BRIEF'
Retrospect the launcher session.
BRIEF
expect_status 0
expect_agy_option --model gemini-4-neon-high
expect_agy_option --effort high
expect_agy_option --mode auto
expect_agy_flag -i
expect_agy_prompt_contains 'You run the Retro stage:'
expect_agy_prompt_contains '· retro-2 · retro]'
expect_agy_prompt_contains 'retro/SKILL.md'
expect_agy_prompt_contains 'writing-for-agents/SKILL.md'
expect_agy_prompt_contains 'Retrospect the launcher session.'

rm -rf "$fixture_tmp"

# --- an unknown --model fails before a window opens ------------------------

new_fixture
run_subagent launch --stage build --item widget --model critic <<'BRIEF'
Add the widget.
BRIEF
expect_status 0
expect_pi_option --model github-copilot/gpt-6.2-sol

for bad_model in bogus /model provider/ 'a b/c'; do
    rm -f "$fixture_log"
    run_subagent launch --stage build --item widget --model "$bad_model" <<'BRIEF'
Add the widget.
BRIEF
    expect_nonzero
    expect_stderr_contains '--model takes a role (builder, writer, critic)'
    expect_no_rex_command
done

rm -rf "$fixture_tmp"

# --- launch output stays valid JSON when the path needs escaping -------------

new_fixture
fixture_repo="$fixture_tmp/a\"b"
mv "$fixture_tmp/repo" "$fixture_repo"
run_subagent launch --stage build --item widget <<'BRIEF'
Add the widget.
BRIEF
expect_status 0
checks=$((checks + 1))
printf '%s' "$output" | python3 -c 'import json, sys
launch = json.load(sys.stdin)
expected = {"window": "win-1", "block": "blk-1", "report": sys.argv[1]}
if not launch["name"].startswith("subagent-build-"):
    sys.exit(1)
if any(launch.get(key) != value for key, value in expected.items()):
    sys.exit(1)' "$fixture_repo/.agents/reports/widget-build.md" ||
    fail "launch output is not JSON a caller can parse for a path with a quote: $output"

rm -rf "$fixture_tmp"

# --- repeated launches on the same item do not overwrite prior reports ------

new_fixture
mkdir -p "$fixture_repo/.agents/reports"
: > "$fixture_repo/.agents/reports/widget-build.md"
run_subagent launch --stage build --item widget <<'BRIEF'
Second round.
BRIEF
expect_status 0
expect_contains "\"report\":\"$fixture_repo/.agents/reports/widget-build-r2.md\""
expect_prompt_contains "$fixture_repo/.agents/reports/widget-build-r2.md"

: > "$fixture_repo/.agents/reports/widget-build-r2.md"
run_subagent launch --stage build --item widget <<'BRIEF'
Third round.
BRIEF
expect_status 0
expect_contains "\"report\":\"$fixture_repo/.agents/reports/widget-build-r3.md\""

rm -rf "$fixture_tmp"

# --- an agent that dies at startup makes launch fail ------------------------

new_fixture
fixture_process='{"last_exit":1}'
run_subagent launch --stage research --item widget <<'BRIEF'
Find out how the widget is built.
BRIEF
expect_nonzero
expect_stderr_contains 'agent start failed'
expect_stderr_contains 'simulated agent crash on startup'

rm -rf "$fixture_tmp"

if [ "$failures" -gt 0 ]; then
    printf '\n%s of %s checks failed\n' "$failures" "$checks"
    exit 1
fi

printf 'ok - %s checks\n' "$checks"

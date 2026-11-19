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
    fixture_stderr="$fixture_tmp/stderr"
    fixture_process=

    mkdir -p "$fixture_repo" "$fixture_home" "$fixture_bin" "$fixture_tmp/tmp"

    git -C "$fixture_repo" init -q
    git -C "$fixture_repo" -c user.email=subagent@test -c user.name=subagent \
        commit -q --allow-empty -m fixture

    # Every skill the Stage table names, installed in the throwaway HOME.
    for skill in research tdd coding writing-for-agents zero-tech-debt review; do
        mkdir -p "$fixture_home/.agents/skills/$skill"
        printf -- '---\nname: %s\n---\n' "$skill" > "$fixture_home/.agents/skills/$skill/SKILL.md"
    done

    # rex stub: records its command line, hands back window ids, reports the
    # block's process. The window's child command is never run.
    cat > "$fixture_bin/rex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REX_STUB_LOG"
case " $* " in
    *" window new "*)
        # The prompt travels as a file argument of the child command. Copy it,
        # then remove it, as the child does once it has read the prompt.
        for arg in "$@"; do
            case $arg in
                */subagent-*.??????)
                    cp "$arg" "$REX_STUB_PROMPT"
                    rm -f "$arg"
                    ;;
            esac
        done
        printf '{"window_id":"win-1","block_ids":["blk-1"]}\n'
        ;;
    *" block call "*)
        printf '%s\n' "${REX_STUB_PROCESS:-{\"last_exit\":null}}"
        ;;
    *" capture "*)
        printf 'simulated agent crash on startup\n'
        ;;
esac
STUB

    # recado stub: whoami names the Manager; nothing is delivered.
    cat > "$fixture_bin/recado" <<'STUB'
#!/usr/bin/env bash
case $1 in
    whoami) printf 'recado://local/manager\n' ;;
esac
STUB

    chmod +x "$fixture_bin/rex" "$fixture_bin/recado"
}

run_subagent() { # run_subagent ARGS... < BRIEF
    set +e
    output=$(
        cd "$fixture_repo" || exit 1
        HOME="$fixture_home" \
            PATH="$fixture_bin:$PATH" \
            TMPDIR="$fixture_tmp/tmp" \
            REX_SESSION=session:test \
            REX_STUB_LOG="$fixture_log" \
            REX_STUB_PROMPT="$fixture_prompt" \
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

expect_rex_contains() {
    checks=$((checks + 1))
    if [ ! -f "$fixture_log" ]; then
        fail "rex was never called"
        return
    fi
    case "$(cat "$fixture_log")" in
        *"$1"*) ;;
        *) fail "expected the rex command line to contain '$1'; got:
$(cat "$fixture_log")" ;;
    esac
}

expect_no_rex_command() {
    checks=$((checks + 1))
    if [ -f "$fixture_log" ] && grep -q 'window new' "$fixture_log"; then
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
expect_rex_contains 'window new'
expect_rex_contains '-s session:test subagent-refine-'
checks=$((checks + 1))
case "$(cat "$fixture_log")" in
    *'--focus=false --keep-open --shell=none --json'*) ;;
    *) fail "the window is not opened in the background: $(cat "$fixture_log")" ;;
esac
expect_rex_contains 'pi '
expect_rex_contains '--model github-copilot/gpt-6.1-sol --thinking high'
expect_contains '"name":"subagent-refine-'

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

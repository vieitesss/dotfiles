#!/usr/bin/env bash
# Fixture tests for agents/skills/subagents/scripts/subagent.
#
# Usage: ./tests/subagent.test.sh
#
# Every case runs the launcher in a throwaway git repo with a throwaway HOME,
# and stubs rex, recado, pi, agy, claude and opencode on PATH: no window opens
# and no Subagent starts.

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
    fixture_claude_log="$fixture_tmp/claude.log"
    fixture_claude_prompt="$fixture_tmp/claude-prompt.md"
    fixture_claude_env="$fixture_tmp/claude-env"
    fixture_opencode_log="$fixture_tmp/opencode.log"
    fixture_opencode_prompt="$fixture_tmp/opencode-prompt.md"
    fixture_stderr="$fixture_tmp/stderr"
    fixture_state="$fixture_tmp/state"
    fixture_process=
    fixture_close_fail=
    fixture_close_error=
    fixture_close_refusal=
    SG_CWD=

    mkdir -p "$fixture_repo" "$fixture_home" "$fixture_bin" "$fixture_tmp/tmp"

    git -C "$fixture_repo" init -q
    git -C "$fixture_repo" -c user.email=subagent@test -c user.name=subagent \
        commit -q --allow-empty -m fixture

    # Every skill the Stage table names, installed in the throwaway HOME.
    for skill in research why tdd coding principles writing-for-agents unslop \
        zero-tech-debt retro review interrogate; do
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
        if [ -n "${REX_STUB_PROCESS:-}" ]; then
            printf '%s\n' "$REX_STUB_PROCESS"
        else
            printf '{"last_exit":null}\n'
        fi
        ;;
    'capture '*)
        printf 'simulated agent crash on startup\n'
        ;;
    'window close')
        if [ "${REX_STUB_CLOSE_FAIL:-}" = 1 ]; then
            printf 'Error: window target "%s" not found\n' "$3" >&2
            exit 3
        fi
        # A refusal that talks about "not found" without the window-target
        # wording and exit 3 is still a failed close, not a gone window.
        if [ "${REX_STUB_CLOSE_REFUSAL:-}" = 1 ]; then
            printf 'Error: Rex session not found; window still open\n' >&2
            exit 1
        fi
        if [ -n "${REX_STUB_CLOSE_ERROR:-}" ]; then
            printf 'Rex connection reset; window still open\n' >&2
            exit 1
        fi
        ;;
    *) exit 1 ;;
esac
STUB

    # Run the received shell command without login profiles, which could
    # replace PATH and accidentally resolve a real harness instead of the stub.
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

    # claude stub: record options, environment, and prompt after --.
    cat > "$fixture_bin/claude" <<'STUB'
#!/usr/bin/env bash
set -eu
[ "${PATH%%:*}" = "$STUB_BIN" ] || exit 99
while [ "$#" -gt 0 ]; do
    case $1 in
        --model | --effort | --permission-mode | --append-system-prompt)
            printf '%s=%s\n' "$1" "$2" >> "$CLAUDE_STUB_LOG"
            shift 2
            ;;
        --)
            shift
            [ "$#" -eq 1 ] || exit 1
            printf '%s\n' "$1" > "$CLAUDE_STUB_PROMPT"
            printf 'CLAUDECODE=%s\n' "$(printenv CLAUDECODE || printf '<unset>')" >> "$CLAUDE_STUB_ENV"
            exit 0
            ;;
        *) exit 1 ;;
    esac
done
exit 1
STUB

    # opencode stub: expect `opencode mini --model M --prompt P`.
    cat > "$fixture_bin/opencode" <<'STUB'
#!/usr/bin/env bash
set -eu
[ "${PATH%%:*}" = "$STUB_BIN" ] || exit 99
[ "${1:-}" = mini ] || exit 1
printf 'subcmd=%s\n' "$1" >> "$OPENCODE_STUB_LOG"
shift
prompt=
while [ "$#" -gt 0 ]; do
    case $1 in
        --model)
            printf '%s=%s\n' "$1" "$2" >> "$OPENCODE_STUB_LOG"
            shift 2
            ;;
        --prompt)
            shift
            [ "$#" -eq 1 ] || exit 1
            prompt=$1
            shift
            ;;
        *) exit 1 ;;
    esac
done
[ -n "$prompt" ] || exit 1
printf '%s\n' "$prompt" > "$OPENCODE_STUB_PROMPT"
STUB

    # recado stub: whoami names the caller; nothing is delivered.
    cat > "$fixture_bin/recado" <<'STUB'
#!/usr/bin/env bash
case $1 in
    whoami) printf 'recado://local/manager\n' ;;
esac
STUB

    chmod +x "$fixture_bin/rex" "$fixture_bin/recado" "$fixture_bin/pi" \
        "$fixture_bin/agy" "$fixture_bin/claude" "$fixture_bin/opencode" "$fixture_bin/shell"
}

run_subagent() { # run_subagent ARGS... < BRIEF
    set +e
    output=$(
        cd "${SG_CWD:-$fixture_repo}" || exit 1
        # Drop the variables the child must set itself, so a value inherited
        # from the caller cannot make the assertion pass.
        env -u CI -u GIT_EDITOR -u GIT_SEQUENCE_EDITOR -u GIT_TERMINAL_PROMPT \
            -u GIT_PAGER -u PAGER -u GH_PROMPT_DISABLED \
            CLAUDECODE=1 \
            HOME="$fixture_home" \
            XDG_STATE_HOME="${SG_XDG_STATE_HOME-$fixture_state}" \
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
            CLAUDE_STUB_LOG="$fixture_claude_log" \
            CLAUDE_STUB_PROMPT="$fixture_claude_prompt" \
            CLAUDE_STUB_ENV="$fixture_claude_env" \
            OPENCODE_STUB_LOG="$fixture_opencode_log" \
            OPENCODE_STUB_PROMPT="$fixture_opencode_prompt" \
            REX_STUB_PROCESS="$fixture_process" \
            REX_STUB_CLOSE_FAIL="$fixture_close_fail" \
            REX_STUB_CLOSE_ERROR="$fixture_close_error" \
            REX_STUB_CLOSE_REFUSAL="$fixture_close_refusal" \
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

expect_file_contains() { # expect_file_contains FILE LABEL NEEDLE
    checks=$((checks + 1))
    if [ ! -f "$1" ]; then
        fail "no $2; rex was called with:
$(cat "$fixture_log" 2>/dev/null)"
        return
    fi
    case "$(cat "$1")" in
        *"$3"*) ;;
        *) fail "expected $2 to contain '$3'; got:
$(cat "$1")" ;;
    esac
}

expect_file_not_contains() { # expect_file_not_contains FILE LABEL NEEDLE
    checks=$((checks + 1))
    if [ ! -f "$1" ]; then
        fail "no $2; rex was called with:
$(cat "$fixture_log" 2>/dev/null)"
        return
    fi
    case "$(cat "$1")" in
        *"$3"*) fail "expected $2 not to contain '$3'; got:
$(cat "$1")" ;;
        *) ;;
    esac
}

expect_prompt_contains() {
    expect_file_contains "$fixture_prompt" "prompt file" "$1"
}

expect_rex_arg() {
    checks=$((checks + 1))
    grep -Fxq -- "$1" "$fixture_log" 2>/dev/null ||
        fail "expected rex to receive argument '$1'; got:
$(cat "$fixture_log" 2>/dev/null)"
}

expect_log_line() { # expect_log_line FILE LABEL LINE
    checks=$((checks + 1))
    grep -Fxq -- "$3" "$1" 2>/dev/null ||
        fail "expected $2 to contain '$3'; got:
$(cat "$1" 2>/dev/null)"
}

expect_row_contains() { # expect_row_contains LABEL NEEDLE: a `stages` row carries NEEDLE
    checks=$((checks + 1))
    row=$(printf '%s\n' "$output" | grep "^$1 " || true)
    case "$row" in
        *"$2"*) ;;
        *) fail "expected the \`stages\` row '$1' to contain '$2'; got:
$row" ;;
    esac
}

expect_pi_option() { expect_log_line "$fixture_pi_log" "pi" "$1=$2"; }
expect_agy_option() { expect_log_line "$fixture_agy_log" "agy" "$1=$2"; }
expect_agy_flag() { expect_log_line "$fixture_agy_log" "agy" "$1"; }
expect_agy_env() { expect_log_line "$fixture_agy_env" "agy env" "$1=$2"; }
expect_agy_prompt_contains() { expect_file_contains "$fixture_agy_prompt" "agy prompt" "$1"; }
expect_claude_option() { expect_log_line "$fixture_claude_log" "claude" "$1=$2"; }
expect_claude_env() { expect_log_line "$fixture_claude_env" "claude env" "$1=$2"; }
expect_claude_prompt_contains() { expect_file_contains "$fixture_claude_prompt" "claude prompt" "$1"; }
expect_opencode_option() { expect_log_line "$fixture_opencode_log" "opencode" "$1=$2"; }
expect_opencode_prompt_contains() { expect_file_contains "$fixture_opencode_prompt" "opencode prompt" "$1"; }

expect_no_rex_command() {
    checks=$((checks + 1))
    if [ -f "$fixture_log" ] && grep -Fxq window "$fixture_log"; then
        fail "expected no window to be opened; rex got:
$(cat "$fixture_log")"
    fi
}

# Start a process with cwd DIR and echo its pid.
leak_proc() { # leak_proc DIR PIDFILE [COMMAND...]
    # The wrapper subshell exits at once, so init reaps the process and
    # `kill -0` tells the truth. `cd` stays outside the backgrounded command:
    # backgrounding an `cd && sleep` list leaves a shell holding the caller's
    # pipe. The process's own stdio is redirected for the same reason.
    lp_dir=$1
    lp_pidfile=$2
    shift 2
    [ $# -gt 0 ] || set -- sleep 300
    (cd "$lp_dir" || exit 1
        "$@" </dev/null >/dev/null 2>&1 &
        printf '%s\n' $! >"$lp_pidfile")
    lp_tries=0
    while [ ! -s "$lp_pidfile" ] && [ "$lp_tries" -lt 50 ]; do
        sleep 0.1
        lp_tries=$((lp_tries + 1))
    done
    cat "$lp_pidfile"
}

use_window_pids() { # use_window_pids PID: the rex stub reports PID as the block's child
    fixture_process="{\"last_exit\":null,\"child\":{\"pid\":$1}}"
}

# --- stages lists harness, model, effort and skills -------------------------

new_fixture
run_subagent stages </dev/null
expect_status 0
expect_contains 'build'
expect_contains 'harness pi'
expect_contains 'harness agy'
expect_contains 'model gemini-4-neon-medium'
expect_contains 'build                    harness pi         model opencode-go/deepseek-v4.1-flash      effort high'
expect_contains 'write                    harness agy        model gemini-4-neon-medium                 effort medium'
expect_contains 'retro                    harness agy        model gemini-4-neon-medium                 effort medium'
expect_contains 'model github-copilot/gpt-6.2-sol'
# Each row owns its skills: a list missing from one row must not pass because
# another row still prints it.
expect_row_contains research 'skills research, why'
expect_row_contains build 'skills tdd, coding, principles'
expect_row_contains write 'skills writing-for-agents, unslop'
expect_row_contains refine 'skills zero-tech-debt, principles'
# The break axis runs on the critic profile, asserted on its own row.
expect_row_contains 'review --axis break' 'skills interrogate'
expect_row_contains 'review --axis break' 'harness pi'
expect_row_contains 'review --axis break' 'model github-copilot/gpt-6.2-sol'
expect_row_contains 'review --axis break' 'effort high'

rm -rf "$fixture_tmp"

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
expect_prompt_contains 'in codemode, summarize or filter in JS so each call returns under ~10 KB (matching lines or <=80-line slices, never raw multi-file dumps).'
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

# --- the break axis loads interrogate; the other axes keep review ----------

new_fixture
run_subagent launch --stage review --axis break --item widget <<'BRIEF'
Find what this change breaks.
BRIEF
expect_status 0
expect_prompt_contains 'interrogate/SKILL.md'
expect_file_not_contains "$fixture_prompt" "prompt file" 'review/SKILL.md'
expect_prompt_contains 'break-axis adversary the interrogate skill describes'
expect_contains '"name":"subagent-review-'

for axis in spec standards debt; do
    rm -f "$fixture_prompt"
    run_subagent launch --stage review --axis "$axis" --item widget <<'BRIEF'
Check the change.
BRIEF
    expect_status 0
    expect_prompt_contains 'review/SKILL.md'
    expect_file_not_contains "$fixture_prompt" "prompt file" 'interrogate/SKILL.md'
    expect_prompt_contains "Review stage, $axis axis"
done

rm -rf "$fixture_tmp"

# --- each Stage names the skills its work needs ----------------------------

new_fixture
run_subagent launch --stage build --item widget <<'BRIEF'
Add the widget.
BRIEF
expect_status 0
expect_prompt_contains 'tdd/SKILL.md'
expect_prompt_contains 'coding/SKILL.md'
expect_prompt_contains 'principles/SKILL.md'
expect_prompt_contains 'prove it on the surface a user touches'
expect_prompt_contains 'verify-*` skill when one exists'
expect_prompt_contains 'commit the failing repro before the fix'
expect_prompt_contains 'Verdict: VERIFIED | NOT VERIFIED | INCONCLUSIVE'
expect_prompt_contains 'and the command and output behind it'
expect_prompt_contains 'an INCONCLUSIVE verdict or a check on the wrong surface is not a pass'

rm -f "$fixture_prompt"
run_subagent launch --stage refine --item widget <<'BRIEF'
Reshape the widget.
BRIEF
expect_status 0
expect_prompt_contains 'principles/SKILL.md'

rm -f "$fixture_agy_prompt"
run_subagent launch --stage write --item widget <<'BRIEF'
Write the changelog.
BRIEF
expect_status 0
expect_agy_prompt_contains 'unslop/SKILL.md'

rm -f "$fixture_prompt"
run_subagent launch --stage research --item widget <<'BRIEF'
Find out how the widget is built.
BRIEF
expect_status 0
expect_prompt_contains 'why/SKILL.md'

rm -rf "$fixture_tmp"

# --- every Stage prompt carries the shared Stage rules ---------------------

new_fixture
brief_text='Do the stage.'
for stage_pair in research: build: write: refine: review:spec review:break retro:; do
    stage=${stage_pair%%:*}
    axis=${stage_pair#*:}
    rm -f "$fixture_prompt"
    if [ -n "$axis" ]; then
        printf '%s\n' "$brief_text" |
            run_subagent launch --stage "$stage" --axis "$axis" --item rules --harness pi
    else
        printf '%s\n' "$brief_text" |
            run_subagent launch --stage "$stage" --item rules --harness pi
    fi
    expect_status 0
    expect_prompt_contains "The brief's done criterion is the whole bar"
    expect_prompt_contains 'add no gate, check, or scope above it'
    expect_prompt_contains 'Pre-existing'
    expect_prompt_contains 'one line each, never as a finding or a fix'
    expect_prompt_contains 'make it and list it under "Choices made" with its reason'
    expect_prompt_contains 'Product and irreversible choices stay questions: ask, end your turn, and wait for the answer'
    # The Manager reads only this block unless it points at the detail, so
    # every Stage report must open with it.
    expect_prompt_contains 'Open the report with a summary block of at most 10 lines'
    expect_prompt_contains 'verdict (or outcome), what changed, must-fix count, decisions needed'
    expect_prompt_contains "then \`## \` sections"
done

rm -rf "$fixture_tmp"

# --- a missing break-axis or build skill fails before a window opens ------

new_fixture
rm -rf "$fixture_home/.agents/skills/interrogate"
run_subagent launch --stage review --axis break --item widget <<'BRIEF'
Find what this change breaks.
BRIEF
expect_nonzero
expect_stderr_contains 'skills not installed'
expect_stderr_contains 'interrogate'
expect_no_rex_command

rm -rf "$fixture_tmp"

new_fixture
rm -rf "$fixture_home/.agents/skills/principles"
run_subagent launch --stage build --item widget <<'BRIEF'
Add the widget.
BRIEF
expect_nonzero
expect_stderr_contains 'skills not installed'
expect_stderr_contains 'principles'
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
expect_agy_option --model gemini-4-neon-medium
expect_agy_option --effort medium
expect_agy_option --mode auto
expect_agy_flag -i
expect_agy_env GIT_EDITOR true
expect_agy_env GIT_SEQUENCE_EDITOR true
expect_agy_env GIT_TERMINAL_PROMPT 0
expect_agy_env GIT_PAGER cat
expect_agy_env PAGER cat
expect_agy_env GH_PROMPT_DISABLED 1
expect_agy_env CI '<unset>'

rm -rf "$fixture_tmp"

# --- explicit --harness, --model, and --effort override Stage defaults ------

new_fixture
run_subagent launch --stage retro --item retro-2 --harness agy --model gemini-4-neon-high --effort medium <<'BRIEF'
Retrospect the launcher session.
BRIEF
expect_status 0
expect_agy_option --model gemini-4-neon-high
expect_agy_option --effort medium
expect_agy_option --mode auto
expect_agy_flag -i
expect_agy_prompt_contains 'You run the Retro stage:'
expect_agy_prompt_contains '· retro-2 · retro]'
expect_agy_prompt_contains 'retro/SKILL.md'
expect_agy_prompt_contains 'writing-for-agents/SKILL.md'
expect_agy_prompt_contains 'Retrospect the launcher session.'

rm -rf "$fixture_tmp"

# --- --model ROLE swaps the full profile; explicit --effort still wins ------

new_fixture
run_subagent launch --stage build --item widget --model writer --effort low <<'BRIEF'
Draft the guide.
BRIEF
expect_status 0
expect_agy_option --model gemini-4-neon-medium
expect_agy_option --effort low

rm -rf "$fixture_tmp"

# --- ad-hoc launches work without --stage across claude and opencode --------

new_fixture
rm -rf "$fixture_home/.agents/skills"
run_subagent launch --item cmp-claude --harness claude --model opus --effort xhigh <<'BRIEF'
Compare approach A.
BRIEF
expect_status 0
expect_claude_option --model opus
expect_claude_option --effort xhigh
expect_claude_option --permission-mode auto
expect_claude_env CLAUDECODE '<unset>'
expect_claude_prompt_contains '· cmp-claude]'
expect_claude_prompt_contains 'Compare approach A.'
expect_file_not_contains "$fixture_claude_prompt" "claude prompt" "Read and follow these skills:"
expect_file_not_contains "$fixture_claude_prompt" "claude prompt" 'summary block of at most 10 lines'
expect_contains '"name":"subagent-adhoc-'
expect_contains "\"report\":\"$fixture_repo/.agents/reports/cmp-claude.md\""

run_subagent launch --item cmp-oc --harness opencode --model anthropic/claude-sonnet-4-5 <<'BRIEF'
Compare approach B.
BRIEF
expect_status 0
expect_opencode_option subcmd mini
expect_opencode_option --model anthropic/claude-sonnet-4-5
expect_opencode_prompt_contains '· cmp-oc]'
expect_opencode_prompt_contains 'Compare approach B.'
expect_contains "\"report\":\"$fixture_repo/.agents/reports/cmp-oc.md\""

rm -rf "$fixture_tmp"

# --- --axis is rejected without --stage review ------------------------------

new_fixture
run_subagent launch --item widget --axis spec <<'BRIEF'
Check spec.
BRIEF
expect_nonzero
expect_stderr_contains '--axis requires --stage review'
expect_no_rex_command

rm -rf "$fixture_tmp"

# --- invalid --harness, --model, and --effort fail before a window opens ----

new_fixture
for bad_harness in bogus '' 'pi agy'; do
    rm -f "$fixture_log"
    run_subagent launch --stage build --item widget --harness "$bad_harness" <<'BRIEF'
Add the widget.
BRIEF
    expect_nonzero
    expect_stderr_contains '--harness takes pi, agy, claude, or opencode'
    expect_no_rex_command
done

for bad_model in 'a b' ''; do
    rm -f "$fixture_log"
    run_subagent launch --stage build --item widget --model "$bad_model" <<'BRIEF'
Add the widget.
BRIEF
    expect_nonzero
    expect_stderr_contains '--model takes a role (builder, writer, critic)'
    expect_no_rex_command
done

for bad_effort in turbo '' 'high max'; do
    rm -f "$fixture_log"
    run_subagent launch --stage build --item widget --effort "$bad_effort" <<'BRIEF'
Add the widget.
BRIEF
    expect_nonzero
    expect_stderr_contains '--effort takes off, minimal, low, medium, high, xhigh, or max'
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

# --- close stops what the Subagent left running in its worktree ------------

new_fixture
worktree="$fixture_tmp/wt"
git -C "$fixture_repo" worktree add -q "$worktree" -b wt
run_subagent launch --stage build --item widget --cwd "$worktree" <<'BRIEF'
Add the widget.
BRIEF
expect_status 0
expect_contains '"window":"win-1"'
# The window's own tree: a shell that keeps a child asleep in the worktree.
# shellcheck disable=SC2016 # the inner bash expands $!, not this one.
tree=$(leak_proc "$worktree" "$fixture_tmp/tree" \
    bash -c 'sleep 300 & echo $! >"$1"; wait' _ "$fixture_tmp/tree-child")
child=
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -s "$fixture_tmp/tree-child" ]; then
        child=$(cat "$fixture_tmp/tree-child")
        break
    fi
    sleep 0.1
done
use_window_pids "$tree"
# Same worktree, not in this window's tree: another Subagent or a Manager check.
neighbour=$(leak_proc "$worktree" "$fixture_tmp/neighbour")
# Outside the worktree and not in the tree: never close's business.
bystander=$(leak_proc "$fixture_tmp" "$fixture_tmp/bystander")
for pid in "$tree" "$child" "$neighbour" "$bystander"; do
    checks=$((checks + 1))
    kill -0 "$pid" 2>/dev/null || fail "pid $pid did not start"
done

run_subagent close win-1 </dev/null
expect_status 0
expect_stderr_contains "stopped pid $tree"
expect_stderr_contains 'sleep 300'
checks=$((checks + 1))
if kill -0 "$tree" 2>/dev/null; then
    fail "close left pid $tree (the window's tree, in the worktree) running"
fi
checks=$((checks + 1))
if [ -n "$child" ] && kill -0 "$child" 2>/dev/null; then
    fail "close left pid $child, a child of the window's tree, running"
fi
checks=$((checks + 1))
if ! kill -0 "$neighbour" 2>/dev/null; then
    fail "close killed pid $neighbour, which shares the worktree but is not in the window's tree"
fi
checks=$((checks + 1))
if ! kill -0 "$bystander" 2>/dev/null; then
    fail "close killed pid $bystander, whose cwd is outside the worktree"
fi
kill -TERM "$neighbour" "$bystander" 2>/dev/null || true
expect_rex_arg win-1

rm -rf "$fixture_tmp"

# --- a process that ignores SIGINT is terminated after the grace period ----

new_fixture
worktree="$fixture_tmp/wt"
git -C "$fixture_repo" worktree add -q "$worktree" -b wt
run_subagent launch --stage build --item widget --cwd "$worktree" <<'BRIEF'
Add the widget.
BRIEF
expect_status 0
stubborn=$(leak_proc "$worktree" "$fixture_tmp/stubborn" \
    bash -c 'trap "" INT; exec sleep 300')
use_window_pids "$stubborn"

run_subagent close win-1 </dev/null
expect_status 0
expect_stderr_contains "stopped pid $stubborn"
checks=$((checks + 1))
if kill -0 "$stubborn" 2>/dev/null; then
    fail "close left pid $stubborn running; it ignored SIGINT and got no SIGTERM"
fi

rm -rf "$fixture_tmp"

# --- close finds the record from any repo ---------------------------------

new_fixture
worktree="$fixture_tmp/wt"
other_repo="$fixture_tmp/other"
git -C "$fixture_repo" worktree add -q "$worktree" -b wt
mkdir -p "$other_repo"
git -C "$other_repo" init -q
run_subagent launch --stage build --item widget --cwd "$worktree" <<'BRIEF'
Add the widget.
BRIEF
expect_status 0
leaked=$(leak_proc "$worktree" "$fixture_tmp/leaked")
use_window_pids "$leaked"

# The Manager closes from its own repo, not from the launching one.
SG_CWD=$other_repo
run_subagent close win-1 </dev/null
SG_CWD=
expect_status 0
expect_stderr_contains "stopped pid $leaked"
checks=$((checks + 1))
if kill -0 "$leaked" 2>/dev/null; then
    fail "close from another repo left pid $leaked running"
fi

rm -rf "$fixture_tmp"

# --- close leaves the main checkout's processes alone ----------------------

new_fixture
run_subagent launch --stage build --item widget --cwd "$fixture_repo" <<'BRIEF'
Add the widget.
BRIEF
expect_status 0
kept=$(leak_proc "$fixture_repo" "$fixture_tmp/kept")
use_window_pids "$kept"

run_subagent close win-1 </dev/null
expect_status 0
expect_stderr_contains 'not reaping'
checks=$((checks + 1))
if ! kill -0 "$kept" 2>/dev/null; then
    fail "close killed pid $kept, which shares the main checkout's cwd"
fi
kill -TERM "$kept" 2>/dev/null || true

rm -rf "$fixture_tmp"

# --- close reaps the whole worktree when the launch cwd is a subdirectory --

new_fixture
worktree="$fixture_tmp/wt"
git -C "$fixture_repo" worktree add -q "$worktree" -b wt
mkdir -p "$worktree/nested"
run_subagent launch --stage build --item widget --cwd "$worktree/nested" <<'BRIEF'
Add the widget.
BRIEF
expect_status 0
own=$(leak_proc "$worktree" "$fixture_tmp/own")
use_window_pids "$own"

run_subagent close win-1 </dev/null
expect_status 0
expect_stderr_contains "stopped pid $own"
checks=$((checks + 1))
if kill -0 "$own" 2>/dev/null; then
    fail "close left pid $own running: it sits at the worktree root and the launch cwd was a subdirectory"
fi
kill -TERM "$own" 2>/dev/null || true

rm -rf "$fixture_tmp"

# --- close reaps nothing under the main checkout ---------------------------

new_fixture
mkdir -p "$fixture_repo/subdir"
run_subagent launch --stage build --item widget --cwd "$fixture_repo/subdir" <<'BRIEF'
Add the widget.
BRIEF
expect_status 0
kept=$(leak_proc "$fixture_repo/subdir" "$fixture_tmp/kept")
use_window_pids "$kept"

run_subagent close win-1 </dev/null
expect_status 0
expect_stderr_contains 'not reaping'
checks=$((checks + 1))
if ! kill -0 "$kept" 2>/dev/null; then
    fail "close killed pid $kept, whose cwd is a subdirectory of the main checkout"
fi
kill -TERM "$kept" 2>/dev/null || true

rm -rf "$fixture_tmp"

# --- a failing rex close keeps the record and stops nothing ----------------

new_fixture
worktree="$fixture_tmp/wt"
git -C "$fixture_repo" worktree add -q "$worktree" -b wt
run_subagent launch --stage build --item widget --cwd "$worktree" <<'BRIEF'
Add the widget.
BRIEF
expect_status 0
leaked=$(leak_proc "$worktree" "$fixture_tmp/leaked")
use_window_pids "$leaked"
fixture_close_error=1

run_subagent close win-1 </dev/null
expect_nonzero
expect_stderr_contains 'could not close'
expect_stderr_contains 'Rex connection reset'
checks=$((checks + 1))
if [ ! -f "$fixture_state/subagent/windows/win-1" ]; then
    fail "close dropped the record of a window Rex failed to close"
fi
checks=$((checks + 1))
if ! kill -0 "$leaked" 2>/dev/null; then
    fail "close stopped pid $leaked although the window never closed"
fi

# The record it kept is what a retry uses.
fixture_close_error=
run_subagent close win-1 </dev/null
expect_status 0
expect_stderr_contains "stopped pid $leaked"
checks=$((checks + 1))
if kill -0 "$leaked" 2>/dev/null; then
    fail "the retried close left pid $leaked running"
fi

rm -rf "$fixture_tmp"

# --- a Rex refusal that says "not found" is not a gone window --------------

new_fixture
worktree="$fixture_tmp/wt"
git -C "$fixture_repo" worktree add -q "$worktree" -b wt
run_subagent launch --stage build --item widget --cwd "$worktree" <<'BRIEF'
Add the widget.
BRIEF
expect_status 0
leaked=$(leak_proc "$worktree" "$fixture_tmp/leaked")
use_window_pids "$leaked"
# Exit 1, and the message holds "not found" without naming the window target.
fixture_close_refusal=1

run_subagent close win-1 </dev/null
expect_nonzero
expect_stderr_contains 'could not close'
checks=$((checks + 1))
if [ ! -f "$fixture_state/subagent/windows/win-1" ]; then
    fail "close dropped the record of a window Rex refused to close"
fi
checks=$((checks + 1))
if ! kill -0 "$leaked" 2>/dev/null; then
    fail "close reaped pid $leaked because a Rex refusal mentioned 'not found'"
fi
kill -TERM "$leaked" 2>/dev/null || true

rm -rf "$fixture_tmp"

# --- close rejects a PID field that is not a process id --------------------

new_fixture
worktree="$fixture_tmp/wt"
git -C "$fixture_repo" worktree add -q "$worktree" -b wt
run_subagent launch --stage build --item widget --cwd "$worktree" <<'BRIEF'
Add the widget.
BRIEF
expect_status 0
other=$(leak_proc "$worktree" "$fixture_tmp/other")
# Word splitting would turn the pid inside this string into a signal target.
fixture_process="{\"child\":{\"pid\":\"garbage $other\"}}"

run_subagent close win-1 </dev/null
expect_status 0
expect_stderr_contains 'cannot read the process tree'
checks=$((checks + 1))
if ! kill -0 "$other" 2>/dev/null; then
    fail "close signalled pid $other because its pid appeared inside a malformed PID field"
fi
kill -TERM "$other" 2>/dev/null || true

rm -rf "$fixture_tmp"

# --- close rejects a PID string that differs only by a trailing newline ----

new_fixture
worktree="$fixture_tmp/wt"
git -C "$fixture_repo" worktree add -q "$worktree" -b wt
run_subagent launch --stage build --item widget --cwd "$worktree" <<'BRIEF'
Add the widget.
BRIEF
expect_status 0
other=$(leak_proc "$worktree" "$fixture_tmp/other")
# Command substitution strips the trailing newline, so the digits alone would
# reach the check as a usable pid.
fixture_process="{\"child\":{\"pid\":\"$other\n\"}}"

run_subagent close win-1 </dev/null
expect_status 0
expect_stderr_contains 'cannot read the process tree'
checks=$((checks + 1))
if ! kill -0 "$other" 2>/dev/null; then
    fail "close signalled pid $other from a PID string with a trailing newline"
fi
kill -TERM "$other" 2>/dev/null || true

rm -rf "$fixture_tmp"

# --- close treats a null PID field as an unknown tree ----------------------

new_fixture
worktree="$fixture_tmp/wt"
git -C "$fixture_repo" worktree add -q "$worktree" -b wt
run_subagent launch --stage build --item widget --cwd "$worktree" <<'BRIEF'
Add the widget.
BRIEF
expect_status 0
kept=$(leak_proc "$worktree" "$fixture_tmp/kept")
fixture_process='{"child":{"pid":null}}'

run_subagent close win-1 </dev/null
expect_status 0
expect_stderr_contains 'cannot read the process tree'
checks=$((checks + 1))
if ! kill -0 "$kept" 2>/dev/null; then
    fail "close reaped pid $kept from a null PID field"
fi
kill -TERM "$kept" 2>/dev/null || true

rm -rf "$fixture_tmp"

# --- close does not escalate to a process that left the worktree -----------

new_fixture
worktree="$fixture_tmp/wt"
git -C "$fixture_repo" worktree add -q "$worktree" -b wt
outside="$fixture_tmp/outside"
mkdir -p "$outside"
run_subagent launch --stage build --item widget --cwd "$worktree" <<'BRIEF'
Add the widget.
BRIEF
expect_status 0
# A process that leaves for OUTSIDE when it takes the SIGINT, and keeps running.
# Python, because a background job of this suite carries SIGINT ignored.
mover=$(leak_proc "$worktree" "$fixture_tmp/mover" \
    python3 -c 'import os, signal, sys, time

def move(*_):
    os.chdir(sys.argv[1])
    open(sys.argv[2], "w").close()

signal.signal(signal.SIGINT, move)
while True:
    time.sleep(0.05)' "$outside" "$fixture_tmp/moved")
use_window_pids "$mover"

run_subagent close win-1 </dev/null
expect_status 0
expect_stderr_contains "pid $mover left"
expect_stderr_contains 'not terminating'
checks=$((checks + 1))
[ -f "$fixture_tmp/moved" ] || fail "close did not deliver SIGINT to pid $mover before escalating"
checks=$((checks + 1))
if ! kill -0 "$mover" 2>/dev/null; then
    fail "close terminated pid $mover after it left the worktree for $outside"
fi
kill -TERM "$mover" 2>/dev/null || true

rm -rf "$fixture_tmp"

# --- close reaps a worktree whose path holds a backslash -------------------

new_fixture
worktree="$fixture_tmp/wt\\back"
git -C "$fixture_repo" worktree add -q "$worktree" -b wt
run_subagent launch --stage build --item widget --cwd "$worktree" <<'BRIEF'
Add the widget.
BRIEF
expect_status 0
own=$(leak_proc "$worktree" "$fixture_tmp/own")
use_window_pids "$own"

run_subagent close win-1 </dev/null
expect_status 0
expect_stderr_contains "stopped pid $own"
checks=$((checks + 1))
if kill -0 "$own" 2>/dev/null; then
    fail "close left pid $own running in a worktree whose path holds a backslash"
fi
kill -TERM "$own" 2>/dev/null || true

rm -rf "$fixture_tmp"

# --- a relative XDG_STATE_HOME falls back to HOME -------------------------

new_fixture
worktree="$fixture_tmp/wt"
other_repo="$fixture_tmp/other"
git -C "$fixture_repo" worktree add -q "$worktree" -b wt
mkdir -p "$other_repo"
git -C "$other_repo" init -q
SG_XDG_STATE_HOME=relative-state
run_subagent launch --stage build --item widget --cwd "$worktree" <<'BRIEF'
Add the widget.
BRIEF
expect_status 0
checks=$((checks + 1))
if [ ! -f "$fixture_home/.local/state/subagent/windows/win-1" ]; then
    fail "a relative XDG_STATE_HOME did not fall back to \$HOME/.local/state"
fi
checks=$((checks + 1))
if [ -e "$fixture_repo/relative-state" ]; then
    fail "a relative XDG_STATE_HOME created state under the launch directory"
fi
leaked=$(leak_proc "$worktree" "$fixture_tmp/leaked")
use_window_pids "$leaked"

SG_CWD=$other_repo
run_subagent close win-1 </dev/null
SG_CWD=
SG_XDG_STATE_HOME=
expect_status 0
expect_stderr_contains "stopped pid $leaked"
checks=$((checks + 1))
if kill -0 "$leaked" 2>/dev/null; then
    fail "close from another directory lost the record written with a relative XDG_STATE_HOME"
fi

rm -rf "$fixture_tmp"

# --- close says so when it cannot read the window's process tree ----------

new_fixture
worktree="$fixture_tmp/wt"
git -C "$fixture_repo" worktree add -q "$worktree" -b wt
run_subagent launch --stage build --item widget --cwd "$worktree" <<'BRIEF'
Add the widget.
BRIEF
expect_status 0
kept=$(leak_proc "$worktree" "$fixture_tmp/kept")
fixture_process='not json'

run_subagent close win-1 </dev/null
expect_status 0
expect_stderr_contains 'cannot read the process tree'
checks=$((checks + 1))
if ! kill -0 "$kept" 2>/dev/null; then
    fail "close guessed at a tree it could not read and killed pid $kept"
fi
kill -TERM "$kept" 2>/dev/null || true

rm -rf "$fixture_tmp"

# --- close succeeds when the window is already gone -----------------------

new_fixture
fixture_close_fail=1
run_subagent close win-1 </dev/null
expect_status 0
expect_stderr_contains 'already gone'

rm -rf "$fixture_tmp"

if [ "$failures" -gt 0 ]; then
    printf '\n%s of %s checks failed\n' "$failures" "$checks"
    exit 1
fi

printf 'ok - %s checks\n' "$checks"

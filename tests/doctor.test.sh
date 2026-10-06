#!/usr/bin/env bash
# Fixture tests for scripts/doctor.
#
# Usage: ./tests/doctor.test.sh
#
# Each case builds a throwaway repo + HOME under a temp directory, so the real
# HOME and the real symlinks are never touched.

set -eu

repo_root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)
doctor_src="$repo_root/scripts/doctor"

failures=0
checks=0

new_fixture() {
    # The name may contain spaces: paths with spaces must survive unquoted
    # string splitting in the doctor.
    fixture_name=${1:-doctor-test}
    # install.sh records canonical source paths (pwd -P), so the fixture must too.
    fixture_tmp=$(CDPATH='' cd "$(mktemp -d "${TMPDIR:-/tmp}/$fixture_name.XXXXXX")" && pwd -P)
    fixture_repo="$fixture_tmp/repo"
    fixture_home="$fixture_tmp/home"

    mkdir -p \
        "$fixture_repo/scripts" \
        "$fixture_repo/agents/skills/placeholder" \
        "$fixture_home/.agents/skills" \
        "$fixture_home/.claude/skills"
    printf '# placeholder\n' > "$fixture_repo/agents/skills/placeholder/SKILL.md"

    cp "$doctor_src" "$fixture_repo/scripts/doctor"

    # The wildcard source exists and is non-empty, so it is never reported.
    printf 'agents/skills/*|~/.agents/skills/*\n' > "$fixture_repo/MAC.manifest"
    printf 'agents/skills/*|~/.agents/skills/*\n' > "$fixture_repo/LINUX.manifest"
}

run_doctor() {
    fixture_bin=$1
    set +e
    output=$(HOME="$fixture_home" "$fixture_bin" 2>&1)
    status=$?
    set -e
}

fail() {
    failures=$((failures + 1))
    printf 'FAIL: %s\n' "$1"
}

expect_contains() {
    checks=$((checks + 1))
    case "$output" in
        *"$1"*) ;;
        *) fail "expected output to contain '$1'; got:
$output" ;;
    esac
}

expect_not_contains() {
    checks=$((checks + 1))
    case "$output" in
        *"$1"*) fail "expected output to not contain '$1'; got:
$output" ;;
    esac
}

expect_status() {
    checks=$((checks + 1))
    [ "$status" -eq "$1" ] || fail "expected exit $1, got $status; output:
$output"
}

expect_count() {
    checks=$((checks + 1))
    actual=$(printf '%s\n' "$output" | grep -c -- "$1" || true)
    [ "$actual" -eq "$2" ] || fail "expected $2 line(s) matching '$1', got $actual; output:
$output"
}

expect_fix_command_parses() {
    checks=$((checks + 1))
    fix_line=$(printf '%s\n' "$output" | sed -n 's/^  fix: //p' | head -n 1)
    if [ -z "$fix_line" ]; then
        fail "expected a printed fix command; got:
$output"
    elif ! bash -n -c "$fix_line" 2>/dev/null; then
        fail "printed fix command is not parseable bash: $fix_line"
    fi
}

# --- missing manifest source is reported -------------------------------------

new_fixture
printf 'missing/thing|~/.config/thing\n' >> "$fixture_repo/MAC.manifest"
printf 'missing/linux-thing|~/.config/linux-thing\n' >> "$fixture_repo/LINUX.manifest"
run_doctor "$fixture_repo/scripts/doctor"
expect_status 1
expect_count '^MISSING SOURCE: missing/thing (MAC.manifest)$' 1
expect_count '^MISSING SOURCE: missing/linux-thing (LINUX.manifest)$' 1
expect_count '^MISSING SOURCE: ' 2
expect_contains 'doctor: 2 problem(s) found'

rm -rf "$fixture_tmp"

# --- a wildcard source with no entries is reported as missing ---------------

new_fixture
rm -rf "$fixture_repo/agents/skills/placeholder"
run_doctor "$fixture_repo/scripts/doctor"
expect_status 1
expect_count '^MISSING SOURCE: agents/skills/\* (MAC.manifest)$' 1
expect_count '^MISSING SOURCE: agents/skills/\* (LINUX.manifest)$' 1

rm -rf "$fixture_tmp"

# --- only dangling repo-owned symlinks are reported --------------------------

new_fixture
mkdir -p "$fixture_repo/agents/skills/valid"
ln -s "$fixture_repo/agents/skills/mine/gone" "$fixture_home/.agents/skills/gone"
ln -s "$fixture_tmp/external/nope" "$fixture_home/.agents/skills/external-dangling"
mkdir "$fixture_home/.claude/skills/real-dir"
ln -s "$fixture_repo/agents/skills/valid" "$fixture_home/.claude/skills/valid"
run_doctor "$fixture_repo/scripts/doctor"
expect_status 1
expect_count '^DANGLING LINK: ' 1
expect_contains "DANGLING LINK: $fixture_home/.agents/skills/gone -> $fixture_repo/agents/skills/mine/gone"
expect_contains "fix: rm $fixture_home/.agents/skills/gone && ./install.sh"
expect_not_contains 'external-dangling'
expect_not_contains 'real-dir'
expect_not_contains "skills/valid"

rm -rf "$fixture_tmp"

# --- a clean setup exits zero ------------------------------------------------

new_fixture
mkdir -p "$fixture_repo/agents/skills/valid"
ln -s "$fixture_repo/agents/skills/valid" "$fixture_home/.agents/skills/valid"
mkdir "$fixture_home/.claude/skills/real-dir"
run_doctor "$fixture_repo/scripts/doctor"
expect_status 0
expect_not_contains 'MISSING SOURCE'
expect_not_contains 'DANGLING LINK'
expect_contains 'doctor: OK'

rm -rf "$fixture_tmp"

# --- a HOME and repo root containing spaces still report dangling links ------

spaced_name='doctor test'
new_fixture "$spaced_name"
ln -s "$fixture_repo/agents/skills/mine/gone" "$fixture_home/.agents/skills/gone"
run_doctor "$fixture_repo/scripts/doctor"
expect_status 1
expect_not_contains 'MISSING SOURCE'
expect_count '^DANGLING LINK: ' 1
expect_contains "DANGLING LINK: $fixture_home/.agents/skills/gone -> $fixture_repo/agents/skills/mine/gone"

rm -rf "$fixture_tmp"

# --- a link named with an apostrophe prints a parseable fix command ----------

new_fixture
ln -s "$fixture_repo/agents/skills/mine/gone" "$fixture_home/.agents/skills/user's-skill"
run_doctor "$fixture_repo/scripts/doctor"
expect_status 1
expect_count '^DANGLING LINK: ' 1
expect_contains "DANGLING LINK: $fixture_home/.agents/skills/user's-skill -> $fixture_repo/agents/skills/mine/gone"
expect_fix_command_parses

rm -rf "$fixture_tmp"

# --- dangling repo-owned links under ~/.claude/skills are reported too -------

new_fixture
ln -s "$fixture_repo/agents/skills/mine/gone" "$fixture_home/.claude/skills/gone"
run_doctor "$fixture_repo/scripts/doctor"
expect_status 1
expect_count '^DANGLING LINK: ' 1
expect_contains "DANGLING LINK: $fixture_home/.claude/skills/gone"

rm -rf "$fixture_tmp"

# --- a doctor run from a linked worktree still sees main-checkout links -------

if command -v git >/dev/null 2>&1; then
    new_fixture
    git -C "$fixture_repo" init -q
    git -C "$fixture_repo" -c user.email=doctor@test -c user.name=doctor add -A
    git -C "$fixture_repo" -c user.email=doctor@test -c user.name=doctor commit -qm fixture
    git -C "$fixture_repo" worktree add -q "$fixture_tmp/worktree"

    mkdir -p "$fixture_tmp/worktree/agents/skills/valid"
    ln -s "$fixture_repo/agents/skills/mine/gone" "$fixture_home/.agents/skills/gone"

    run_doctor "$fixture_tmp/worktree/scripts/doctor"
    expect_status 1
    expect_not_contains 'MISSING SOURCE'
    expect_count '^DANGLING LINK: ' 1
    expect_contains "-> $fixture_repo/agents/skills/mine/gone"

    rm -rf "$fixture_tmp"
else
    printf 'skip - git not available for the linked-worktree case\n'
fi

if [ "$failures" -gt 0 ]; then
    printf '\n%s of %s checks failed\n' "$failures" "$checks"
    exit 1
fi

printf 'ok - %s checks\n' "$checks"

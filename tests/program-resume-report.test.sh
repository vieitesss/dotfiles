#!/bin/sh
# Test for scripts/program-resume-report, scripts/agy-resume-hook and the
# scripts/antigravity name the hook reports.
# Run: sh tests/program-resume-report.test.sh
#
# The program writes its report to a tty device, so the tests point it at a
# file. The hook asks ps about its parents and calls the reporter, so the
# tests answer ps from AGY_RESUME_PS and the reporter from a PATH stub.

set -eu

repo_root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
report=$repo_root/scripts/program-resume-report
hook=$repo_root/scripts/agy-resume-hook
shim=$repo_root/scripts/antigravity
esc=$(printf '\033')

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# The same digest the report uses, chosen the same way.
sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | cut -d' ' -f1
    else
        sha256sum | cut -d' ' -f1
    fi
}

# The spec's test vector. It prints the text and the token but no digest, so
# a second implementation checks that the recipe is read the same way: the
# body before ":mac=", one ":", the token, and nothing after it.
vector='pid=74877:time=1795543200:clear=1:dummy-token-replace-me'
[ "${#vector}" -eq 56 ] || fail "mac vector: ${#vector} bytes, want 56"
got=$(printf '%s' "$vector" | sha256)
case $got in
    *[!0-9a-f]* | '') fail "mac vector: $got" ;;
esac
[ "${#got}" -eq 64 ] || fail "mac vector: ${#got} hex, want 64"
if command -v openssl >/dev/null 2>&1; then
    want=$(printf '%s' "$vector" | openssl dgst -sha256 | awk '{print $NF}')
    [ "$got" = "$want" ] || fail "mac vector: $got, openssl says $want"
fi

# One record, framed as ESC ] 7577 ; BODY ESC \, with each argv element in
# base64 and the pid it was given.
osc=$tmp/osc
OSC7577_TOKEN=token-replace-me "$report" 4242 "$osc" antigravity --model opus 'a b' ||
    fail 'report exited non-zero'
record=$(cat "$osc")
case $record in
    "$esc]7577;"*"$esc\\") ;;
    *) fail "report framing: $record" ;;
esac
body=${record#"$esc]7577;"}
body=${body%"$esc\\"}
mac=${body##*:mac=}
signed=${body%:mac=*}
case $signed in
    'pid=4242:time='*) ;;
    *) fail "report body: $signed" ;;
esac
# The mac covers the body before ":mac=", then ":", then the token, with
# nothing after the token: a trailing newline would change the digest.
printf '%s' "$signed:token-replace-me" | sha256 | grep -qx "$mac" ||
    fail "report mac: $mac"
case $mac in
    *[!0-9a-f]* | '') fail "report mac is not lowercase hex: $mac" ;;
esac
[ "${#mac}" -eq 64 ] || fail "report mac: ${#mac} hex, want 64"

argv=${signed#*:argv=}
[ "$argv" != "$signed" ] || fail "report has no argv: $signed"
decoded=
for word in $(printf '%s' "$argv" | tr ',' ' '); do
    decoded="$decoded$(printf '%s' "$word" | base64 -d)|"
done
[ "$decoded" = 'antigravity|--model|opus|a b|' ] || fail "report argv: $decoded"

# Without the terminal's token there is nothing to report, and no file.
OSC7577_TOKEN='' "$report" 4242 "$tmp/no-token" antigravity || fail 'no token: non-zero'
[ ! -e "$tmp/no-token" ] || fail 'no token: wrote a report'

# The name Rex finds the process by runs agy again.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/agy" <<'STUB'
#!/bin/sh
printf '%s\n' "$@"
STUB
chmod +x "$tmp/bin/agy"
want=$(printf '%s\n' --conversation 11111111-2222-3333-4444-555555555555 --sandbox)
got=$(PATH="$tmp/bin:$PATH" "$shim" --conversation 11111111-2222-3333-4444-555555555555 --sandbox) ||
    fail 'antigravity: non-zero'
[ "$got" = "$want" ] || fail "antigravity args: $got"

# Rex can only run the command the rule trusts when the name is on PATH.
for manifest in MAC.manifest LINUX.manifest; do
    grep -qx 'scripts/antigravity|~/.local/bin/antigravity' "$repo_root/$manifest" ||
        fail "antigravity is not linked in $manifest"
done

# The hook rebuilds the command line: antigravity, the conversation, then the
# flags the resume rule keeps. Its keep list and the rule must agree.
cat >"$tmp/bin/program-resume-report" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" >"$AGY_RESUME_CALLS"
STUB
chmod +x "$tmp/bin/program-resume-report"

rule_flags=$(
    sed -n '/rex.set("resume.trust.antigravity"/,/^})/p' "$repo_root/rex/init.lua" |
        grep -E '^[[:space:]]*\["' |
        sed -e 's/^[[:space:]]*\["\([^"]*\)"\][[:space:]]*=[[:space:]]*{[[:space:]]*"keep",[[:space:]]*values[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*}.*/\1 \2/' \
            -e 's/^[[:space:]]*\["\([^"]*\)"\][[:space:]]*=[[:space:]]*"keep".*/\1 0/' |
        grep -E '^--' |
        sort
)
[ -n "$rule_flags" ] || fail 'no keep flags read from rex/init.lua'
hook_flags=$(sed -n "/^kept_flags='/,/^'$/p" "$hook" | sed '1d;$d' | sort)
[ "$rule_flags" = "$hook_flags" ] || {
    printf 'FAIL: hook keep list and resume rule disagree\n' >&2
    printf '%s\n' "$hook_flags" >"$tmp/hook-flags"
    printf '%s\n' "$rule_flags" >"$tmp/rule-flags"
    diff -u "$tmp/hook-flags" "$tmp/rule-flags" >&2 || true
    exit 1
}

cat >"$tmp/bin/ps" <<'STUB'
#!/bin/sh
# Answers the three ps queries the hook makes from AGY_RESUME_TREE, whose
# lines are pid|ppid|comm|tty|args. The row "*" answers for the hook itself.
if [ -n "${AGY_RESUME_PS_LOG:-}" ]; then
    printf '%s\n' "$*" >>"$AGY_RESUME_PS_LOG"
fi
field=
pid=
while [ "$#" -gt 0 ]; do
    case $1 in
        -o) field=$2; shift 2 ;;
        -p) pid=$2; shift 2 ;;
        *) shift ;;
    esac
done
row=$(awk -F'|' -v pid="$pid" '$1 == pid { print; exit }' "$AGY_RESUME_TREE")
[ -n "$row" ] || row=$(awk -F'|' -v pid='*' '$1 == pid { print; exit }' "$AGY_RESUME_TREE")
[ -n "$row" ] || exit 1
ppid=$(printf '%s\n' "$row" | cut -d'|' -f2)
comm=$(printf '%s\n' "$row" | cut -d'|' -f3)
tty=$(printf '%s\n' "$row" | cut -d'|' -f4)
args=$(printf '%s\n' "$row" | cut -d'|' -f5-)
case $field in
    'ppid=,comm=') printf ' %s %s\n' "$ppid" "$comm" ;;
    'tty=') printf '%s\n' "$tty" ;;
    'args=') printf '%s\n' "$args" ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/ps"

# A tree whose antigravity carries the flags the rule keeps, the flags it
# drops, and a one-word prompt for -i.
tree() {
    cat >"$1" <<'TREE'
*|4002|/bin/sh|ttys001|/bin/sh -c agy-resume-hook
4002|4001|/bin/sh|ttys019|/bin/sh -c agy-resume-hook
4001|1|/opt/homebrew/Caskroom/antigravity-cli/1.5.13/antigravity|ttys019|/opt/homebrew/Caskroom/antigravity-cli/1.5.13/antigravity --model opus --conversation old-uuid --add-dir one --add-dir two -i hello --sandbox --continue
TREE
}

cat >"$tmp/in-conversation" <<'JSON'
{"conversationId": "11111111-2222-3333-4444-555555555555", "workspacePaths": ["/tmp"], "modelName": "opus"}
JSON

# hook_out TREE INPUT [PATH] -> stdout; stderr lands in $tmp/err.
hook_out() {
    PATH="${3:-$tmp/bin:$PATH}" AGY_RESUME_PS="$tmp/bin/ps" \
        AGY_RESUME_PS_LOG="$tmp/pslog" AGY_RESUME_TREE="$1" \
        AGY_RESUME_CALLS="$tmp/calls" OSC7577_TOKEN=token-replace-me \
        "$hook" <"$2" 2>"$tmp/err"
}

# The conversation comes first, so the reported argv starts with the rule's
# command, and only the kept flags follow the dropped ones.
rm -f "$tmp/calls"
: >"$tmp/pslog"
tree "$tmp/tree"
out=$(hook_out "$tmp/tree" "$tmp/in-conversation") || fail 'hook exited non-zero'
[ "$out" = '{}' ] || fail "hook stdout: $out"
[ ! -s "$tmp/err" ] || fail "hook stderr: $(cat "$tmp/err")"
cat >"$tmp/want" <<'WANT'
4001
/dev/ttys019
antigravity
--conversation
11111111-2222-3333-4444-555555555555
--model
opus
--add-dir
one
--add-dir
two
--sandbox
WANT
cmp -s "$tmp/calls" "$tmp/want" || {
    printf 'FAIL: hook argv\n' >&2
    diff -u "$tmp/want" "$tmp/calls" >&2 || true
    exit 1
}

# -ww on every ps call: without it macOS cuts the path before the name.
if [ ! -s "$tmp/pslog" ]; then fail 'hook made no ps call'; fi
if grep -q -v -- '-ww' "$tmp/pslog"; then
    fail "ps call without -ww: $(grep -v -- '-ww' "$tmp/pslog" | head -1)"
fi

# A prompt behind -i or --prompt-interactive is dropped whole, however many
# words it holds, so Rex never sees stray arguments or a huge report.
words=
i=0
while [ "$i" -lt 60 ]; do
    words="$words word$i"
    i=$((i + 1))
done
cat >"$tmp/prompt-tree" <<TREE
*|4002|/bin/sh|ttys001|/bin/sh -c agy-resume-hook
4002|4001|/bin/sh|ttys019|/bin/sh -c agy-resume-hook
4001|1|/opt/homebrew/bin/antigravity|ttys019|/opt/homebrew/bin/antigravity --model opus -i two words$words --sandbox --prompt-interactive more words --continue
TREE
rm -f "$tmp/calls"
out=$(hook_out "$tmp/prompt-tree" "$tmp/in-conversation") || fail 'prompt: non-zero'
[ "$out" = '{}' ] || fail "prompt: stdout $out"
cat >"$tmp/want" <<'WANT'
4001
/dev/ttys019
antigravity
--conversation
11111111-2222-3333-4444-555555555555
--model
opus
--sandbox
WANT
cmp -s "$tmp/calls" "$tmp/want" || {
    printf 'FAIL: prompt leaked into argv\n' >&2
    diff -u "$tmp/want" "$tmp/calls" >&2 || true
    exit 1
}

# The --flag=value forms of the kept flags are kept, and of the dropped flags
# are dropped.
cat >"$tmp/equals-tree" <<'TREE'
*|4002|/bin/sh|ttys001|/bin/sh -c agy-resume-hook
4002|4001|/bin/sh|ttys019|/bin/sh -c agy-resume-hook
4001|1|/usr/bin/antigravity|ttys019|/usr/bin/antigravity --model=opus --add-dir=/tmp/x --conversation=old --prompt-interactive=two words --continue=true --sandbox
TREE
rm -f "$tmp/calls"
out=$(hook_out "$tmp/equals-tree" "$tmp/in-conversation") || fail 'equals: non-zero'
[ "$out" = '{}' ] || fail "equals: stdout $out"
cat >"$tmp/want" <<'WANT'
4001
/dev/ttys019
antigravity
--conversation
11111111-2222-3333-4444-555555555555
--model=opus
--add-dir=/tmp/x
--sandbox
WANT
cmp -s "$tmp/calls" "$tmp/want" || {
    printf 'FAIL: --flag=value argv\n' >&2
    diff -u "$tmp/want" "$tmp/calls" >&2 || true
    exit 1
}

# A process with no terminal has no device to report to: Linux prints "?",
# macOS "??", and the hook must not treat either as a path.
for none in '?' '??'; do
    cat >"$tmp/no-tty-tree" <<TREE
*|4002|/bin/sh|ttys001|/bin/sh -c agy-resume-hook
4002|4001|/bin/sh|$none|/bin/sh -c agy-resume-hook
4001|1|/usr/bin/antigravity|$none|/usr/bin/antigravity --model opus
TREE
    rm -f "$tmp/calls"
    out=$(hook_out "$tmp/no-tty-tree" "$tmp/in-conversation") ||
        fail "no tty $none: non-zero"
    [ "$out" = '{}' ] || fail "no tty $none: stdout $out"
    [ ! -s "$tmp/err" ] || fail "no tty $none: stderr $(cat "$tmp/err")"
    [ ! -e "$tmp/calls" ] || fail "no tty $none: reported to /dev/$none"
done

# A reporter that is missing or fails prints nothing: the hook still answers.
mkdir -p "$tmp/psonly"
cp "$tmp/bin/ps" "$tmp/psonly/ps"
rm -f "$tmp/calls"
out=$(hook_out "$tmp/tree" "$tmp/in-conversation" "$tmp/psonly:/usr/bin:/bin") ||
    fail 'missing reporter: non-zero'
[ "$out" = '{}' ] || fail "missing reporter: stdout $out"
[ ! -s "$tmp/err" ] || fail "missing reporter: stderr $(cat "$tmp/err")"

# A session with no conversation, or no antigravity above it, still answers
# "{}" and succeeds.
out=$(hook_out "$tmp/tree" /dev/null) || fail 'no conversation: non-zero'
[ "$out" = '{}' ] || fail "no conversation: stdout $out"

cat >"$tmp/alone" <<'TREE'
*|4002|/bin/sh|ttys001|/bin/sh -c agy-resume-hook
4002|1|/bin/sh|ttys001|/bin/sh
TREE
rm -f "$tmp/calls"
out=$(hook_out "$tmp/alone" "$tmp/in-conversation") || fail 'no antigravity: non-zero'
[ "$out" = '{}' ] || fail "no antigravity: stdout $out"
[ ! -e "$tmp/calls" ] || fail 'no antigravity: reported anyway'

printf 'ok: %s\n' "$0"

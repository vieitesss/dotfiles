#!/bin/sh
# Test for scripts/program-resume-report and scripts/agy-resume-hook.
# Run: sh tests/program-resume-report.test.sh
#
# The program writes its report to a tty device, so the tests point it at a
# file. The hook asks ps about its parents and calls the reporter, so the
# tests answer ps from AGY_RESUME_PS and the reporter from a PATH stub.

set -eu

repo_root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
report=$repo_root/scripts/program-resume-report
hook=$repo_root/scripts/agy-resume-hook
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
OSC7577_TOKEN=token-replace-me "$report" 4242 "$osc" agy --model opus 'a b' ||
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
[ "$decoded" = 'agy|--model|opus|a b|' ] || fail "report argv: $decoded"

# Without the terminal's token there is nothing to report, and no file.
OSC7577_TOKEN='' "$report" 4242 "$tmp/no-token" agy || fail 'no token: non-zero'
[ ! -e "$tmp/no-token" ] || fail 'no token: wrote a report'

# The hook rebuilds the command line: agy, the flags that do not pick a
# conversation, then the conversation agy reports on stdin.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/program-resume-report" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" >"$AGY_RESUME_CALLS"
STUB
chmod +x "$tmp/bin/program-resume-report"

cat >"$tmp/bin/ps" <<'STUB'
#!/bin/sh
# Answers the three ps queries the hook makes from AGY_RESUME_TREE, whose
# lines are pid|ppid|comm|tty|args. The row "*" answers for the hook itself.
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

cat >"$tmp/tree" <<'TREE'
*|4002|/bin/sh|ttys001|/bin/sh -c agy-resume-hook
4002|4001|/bin/sh|ttys019|/bin/sh -c agy-resume-hook
4001|1|/opt/homebrew/Caskroom/antigravity-cli/1.5.13/antigravity|ttys019|/opt/homebrew/Caskroom/antigravity-cli/1.5.13/antigravity --model opus --conversation old-uuid --add-dir one --add-dir two -i hello --sandbox --continue
TREE

out=$(PATH="$tmp/bin:$PATH" AGY_RESUME_PS="$tmp/bin/ps" \
    AGY_RESUME_TREE="$tmp/tree" AGY_RESUME_CALLS="$tmp/calls" \
    OSC7577_TOKEN=token-replace-me "$hook" <<'JSON'
{"conversationId": "11111111-2222-3333-4444-555555555555", "workspacePaths": ["/tmp"], "modelName": "opus"}
JSON
) || fail 'hook exited non-zero'
[ "$out" = '{}' ] || fail "hook stdout: $out"
cat >"$tmp/want" <<'WANT'
4001
/dev/ttys019
agy
--model
opus
--add-dir
one
--add-dir
two
--sandbox
--conversation
11111111-2222-3333-4444-555555555555
WANT
cmp -s "$tmp/calls" "$tmp/want" || {
    printf 'FAIL: hook argv\n' >&2
    diff -u "$tmp/want" "$tmp/calls" >&2 || true
    exit 1
}

# A session with no conversation, or no antigravity above it, still answers
# "{}" and succeeds.
out=$(PATH="$tmp/bin:$PATH" AGY_RESUME_PS="$tmp/bin/ps" \
    AGY_RESUME_TREE="$tmp/tree" AGY_RESUME_CALLS="$tmp/calls" \
    OSC7577_TOKEN=token-replace-me "$hook" <<'JSON'
{"workspacePaths": ["/tmp"]}
JSON
) || fail 'no conversation: non-zero'
[ "$out" = '{}' ] || fail "no conversation: stdout $out"

cat >"$tmp/alone" <<'TREE'
*|4002|/bin/sh|ttys001|/bin/sh -c agy-resume-hook
4002|1|/bin/sh|ttys001|/bin/sh
TREE
out=$(PATH="$tmp/bin:$PATH" AGY_RESUME_PS="$tmp/bin/ps" \
    AGY_RESUME_TREE="$tmp/alone" AGY_RESUME_CALLS="$tmp/calls" \
    OSC7577_TOKEN=token-replace-me "$hook" <<'JSON'
{"conversationId": "11111111-2222-3333-4444-555555555555"}
JSON
) || fail 'no antigravity: non-zero'
[ "$out" = '{}' ] || fail "no antigravity: stdout $out"

printf 'ok: %s\n' "$0"

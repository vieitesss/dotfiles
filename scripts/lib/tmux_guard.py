"""Shared decision core for the dotfiles tmux destructive-command guard.

The guard answers one question for a shell command string handed to an agent
harness: may this command run without a human in the loop?  It never executes
anything, and no environment variable, flag, or token can grant approval -- the
adapters turn ``ask`` into a harness prompt (and into a block when no human can
be prompted).

Decisions are conservative.  A destructive tmux operation is allowed only when
the command explicitly targets a socket that a ``tmux-sandbox`` run owns
(``<tmpdir>/dotfiles-tmux-sandbox.<id>/run/tmux.sock`` with a matching
``state.json``).  Every other destructive form -- unqualified, live, default,
relative, ``-L``, wrapped, chained, aliased, substituted -- is ``ask``.

The guard is a deterministic speed bump, not a sandbox.  See
``docs/tmux-guard.md`` for the limits.
"""

from __future__ import annotations

import json
import os
import re
import stat
import tempfile
from dataclasses import dataclass, field
from typing import Iterable, Mapping, Optional, Tuple

STATE_PREFIX = "dotfiles-tmux-sandbox."
STATE_FILE = "state.json"
SOCKET_RELPATH = os.path.join("run", "tmux.sock")
STATE_VERSION = 1

# tmux command words the guard understands, mapped to ``(kind, canonical)``:
#   "guarded"  -- destructive on the server it targets; only an owned socket
#                 may authorize it
#   "shell"    -- its arguments are shell commands, judged on their own terms
#   "commands" -- its arguments are tmux command lists for the targeted server
# tmux resolves unique prefixes (``kill-serv``, ``run-sh``), so a word matches
# when it is an exact key or a prefix of one.  ``killw``/``killp`` are aliases
# that are not prefixes of their canonical names.
TMUX_COMMANDS = {
    "kill-server": ("guarded", "kill-server"),
    "kill-session": ("guarded", "kill-session"),
    "kill-client": ("guarded", "kill-client"),
    "source-file": ("guarded", "source-file"),
    "kill-window": ("guarded", "kill-window"),
    "killw": ("guarded", "kill-window"),
    "kill-pane": ("guarded", "kill-pane"),
    "killp": ("guarded", "kill-pane"),
    "detach-client": ("guarded", "detach-client"),
    "run-shell": ("shell", "run-shell"),
    "if-shell": ("commands", "if-shell"),
    "bind-key": ("commands", "bind-key"),
    "confirm-before": ("commands", "confirm-before"),
}
SHELLS = {"sh", "bash", "dash", "zsh", "ksh", "mksh", "ash", "fish"}
WRAPPERS = {
    "sudo",
    "doas",
    "command",
    "builtin",
    "exec",
    "nohup",
    "nice",
    "ionice",
    "setsid",
    "stdbuf",
    "env",
    "time",
    "timeout",
    "xargs",
}
# Wrapper options that consume the following word.  Anything not listed is
# treated as a flag without a value.
WRAPPER_VALUE_FLAGS = {
    "env": ("-u", "--unset", "-S", "--split-string", "-C", "--chdir"),
    "sudo": ("-u", "--user", "-g", "--group", "-p", "--prompt", "-C", "--close-from",
             "-h", "--host", "-r", "--role", "-t", "--type", "-U", "--other-user"),
    "doas": ("-u", "-C"),
    "timeout": ("-k", "--kill-after", "-s", "--signal"),
    "xargs": ("-a", "--arg-file", "-d", "--delimiter", "-E", "--eof", "-I", "--replace",
              "-L", "--max-lines", "-n", "--max-args", "-P", "--max-procs",
              "-s", "--max-chars"),
    "nice": ("-n", "--adjustment"),
    "ionice": ("-c", "--class", "-n", "--classdata"),
    "stdbuf": ("-i", "--input", "-o", "--output", "-e", "--error"),
}
# Flags whose attached characters make a conditional command destructive.
DESTRUCTIVE_FLAG_CHARS = {
    "kill-window": ("a",),
    "kill-pane": ("a",),
    "detach-client": ("a", "P"),
}

MAX_DEPTH = 8

VARIABLE_FINDING = (
    "a shell variable holds a destructive tmux operation; "
    "refusing to authorize the command"
)

_OP_CHARS = ";|&<>()"


@dataclass(frozen=True)
class Decision:
    kind: str  # "allow" | "ask"
    reason: str = ""


ALLOW = Decision("allow", "")


@dataclass
class Token:
    text: str
    quoted: bool = False
    op: Optional[str] = None
    subs: Tuple[str, ...] = ()
    consumed: bool = field(default=False)


# --------------------------------------------------------------------------
# tokenizing and segmenting
# --------------------------------------------------------------------------


def tokenize(command: str) -> Optional[list[Token]]:
    """Split a shell command string into conservative tokens.

    Returns ``None`` when quotes are unbalanced, which the caller treats as
    unprovable and asks about.  No expansion is performed: substitutions are
    captured as text on the token for recursive analysis.
    """
    tokens: list[Token] = []
    i = 0
    n = len(command)
    at_word_start = True
    while i < n:
        c = command[i]
        if c in " \t\r":
            at_word_start = True
            i += 1
            continue
        if c == "\n":
            tokens.append(Token("\n", op="\n"))
            at_word_start = True
            i += 1
            continue
        if c == "#" and at_word_start:
            while i < n and command[i] != "\n":
                i += 1
            continue
        if c in _OP_CHARS:
            if c in ";|&" and i + 1 < n and command[i + 1] == c:
                tokens.append(Token(c + c, op=c + c))
                i += 2
            else:
                tokens.append(Token(c, op=c))
                i += 1
            at_word_start = True
            continue
        text: list[str] = []
        quoted = False
        subs: list[str] = []
        while i < n:
            c = command[i]
            if c in " \t\r\n" or c in _OP_CHARS:
                break
            if c == "'":
                end = command.find("'", i + 1)
                if end < 0:
                    return None
                text.append(command[i + 1:end])
                quoted = True
                i = end + 1
                continue
            if c == '"':
                i += 1
                while True:
                    if i >= n:
                        return None
                    c = command[i]
                    if c == "\\" and i + 1 < n and command[i + 1] in '"\\$`':
                        text.append(command[i + 1])
                        i += 2
                        continue
                    if c == '"':
                        i += 1
                        break
                    if (c == "$" and command.startswith("$(", i)) or c == "`":
                        inner, i = _substitution(command, i)
                        if inner is None:
                            return None
                        subs.append(inner)
                        continue
                    text.append(c)
                    i += 1
                quoted = True
                continue
            if c == "\\":
                if i + 1 < n:
                    text.append(command[i + 1])
                    i += 2
                else:
                    i += 1
                continue
            if (c == "$" and command.startswith("$(", i)) or c == "`":
                inner, i = _substitution(command, i)
                if inner is None:
                    return None
                subs.append(inner)
                continue
            text.append(c)
            i += 1
        tokens.append(Token("".join(text), quoted=quoted, subs=tuple(subs)))
        at_word_start = False
    return tokens


def _balanced(command: str, start: int, open_char: str, close_char: str):
    """Return (inner text, index after close) for a balanced substitution."""
    depth = 1
    i = start
    n = len(command)
    while i < n:
        c = command[i]
        if c == "\\" and i + 1 < n:
            i += 2
            continue
        if c == "'":
            end = command.find("'", i + 1)
            if end < 0:
                return None, i
            i = end + 1
            continue
        if c == '"':
            i += 1
            while i < n and command[i] != '"':
                if command[i] == "\\" and i + 1 < n:
                    i += 2
                    continue
                i += 1
            i += 1
            continue
        if c == open_char:
            depth += 1
        elif c == close_char:
            depth -= 1
            if depth == 0:
                return command[start:i], i + 1
        i += 1
    return None, i


def _substitution(command: str, start: int):
    """Inner text and next index for a ``$(...)`` or backtick substitution."""
    if command.startswith("$(", start):
        return _balanced(command, start + 2, "(", ")")
    end = command.find("`", start + 1)
    if end < 0:
        return None, start
    return command[start + 1:end], end + 1


def segments(tokens: list[Token]) -> list[list[Token]]:
    """Split tokens on shell control operators into simple commands."""
    out: list[list[Token]] = []
    current: list[Token] = []
    for token in tokens:
        if token.op is not None:
            if current:
                out.append(current)
                current = []
            continue
        current.append(token)
    if current:
        out.append(current)
    return out


# --------------------------------------------------------------------------
# socket candidates and sandbox ownership
# --------------------------------------------------------------------------


def canonicalize(path: str, cwd: Optional[str] = None) -> str:
    if not os.path.isabs(path):
        path = os.path.join(cwd or os.getcwd(), path)
    return os.path.realpath(path)


def live_socket_paths(env: Mapping[str, str], extra: Iterable[str] = ()) -> list[str]:
    """Sockets a bare tmux invocation may reach, in tmux's resolution order."""
    out: list[str] = [canonicalize(path) for path in extra]
    tmux = env.get("TMUX") or ""
    if tmux and not tmux.startswith(","):
        out.append(canonicalize(tmux.split(",", 1)[0]))
    tmpdir = env.get("TMUX_TMPDIR") or "/tmp"
    out.append(canonicalize(os.path.join(tmpdir, f"tmux-{os.getuid()}", "default")))
    seen: list[str] = []
    for path in out:
        if path not in seen:
            seen.append(path)
    return seen


def default_tmpdir(env: Optional[Mapping[str, str]] = None) -> str:
    if env and env.get("TMPDIR"):
        return canonicalize(env["TMPDIR"])
    return canonicalize(tempfile.gettempdir())


def owned_state_for_socket(socket_path: str, tmpdir: Optional[str] = None) -> Optional[str]:
    """Return the owned sandbox state dir for ``socket_path``, or ``None``.

    Ownership is a conservative file check, not a cryptographic boundary: the
    parent state directory must be a direct child of the temporary directory,
    carry the runner's name, be uid-owned and 0700, and hold a state.json whose
    recorded socket is exactly this socket.
    """
    socket = canonicalize(socket_path)
    if os.path.basename(socket) != os.path.basename(SOCKET_RELPATH):
        return None
    run_dir = os.path.dirname(socket)
    if os.path.basename(run_dir) != os.path.dirname(SOCKET_RELPATH):
        return None
    state = os.path.dirname(run_dir)
    if state == run_dir or not os.path.isabs(state):
        return None
    return state if _state_is_owned(state, socket, tmpdir) else None


def owned_socket_for_state(state: str, tmpdir: Optional[str] = None) -> Optional[str]:
    """Return the socket of a valid owned state dir, or ``None`` if not owned."""
    if not state or not os.path.isabs(state):
        return None
    state = os.path.normpath(state)
    if os.path.realpath(state) != state:
        return None
    socket = canonicalize(os.path.join(state, SOCKET_RELPATH))
    return socket if _state_is_owned(state, socket, tmpdir) else None


def _state_is_owned(state: str, socket: str, tmpdir: Optional[str]) -> bool:
    root = canonicalize(tmpdir) if tmpdir else default_tmpdir()
    if os.path.dirname(state) != root:
        return False
    name = os.path.basename(state)
    if not name.startswith(STATE_PREFIX):
        return False
    if not re.fullmatch(r"[A-Za-z0-9]{6,}", name[len(STATE_PREFIX):]):
        return False
    if os.path.realpath(state) != state:
        return False
    for path in (state, os.path.join(state, os.path.dirname(SOCKET_RELPATH))):
        try:
            info = os.lstat(path)
        except OSError:
            return False
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
            return False
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            return False
    state_file = os.path.join(state, STATE_FILE)
    try:
        info = os.lstat(state_file)
    except OSError:
        return False
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        return False
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        return False
    try:
        with open(state_file, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return False
    return (
        isinstance(data, dict)
        and data.get("version") == STATE_VERSION
        and data.get("socket") == socket
    )


# --------------------------------------------------------------------------
# command analysis
# --------------------------------------------------------------------------


class _Analyzer:
    def __init__(self, cwd: str, env: Mapping[str, str], tmpdir: Optional[str],
                 extra_live: Iterable[str] = ()):
        self.cwd = cwd
        self.env = env
        self.tmpdir = tmpdir if tmpdir is not None else default_tmpdir(env)
        self.live = live_socket_paths(env, extra_live)

    # -- entry points ------------------------------------------------------

    def evaluate_text(self, command: str, depth: int = 0) -> Decision:
        if depth > MAX_DEPTH:
            return Decision("ask", "shell nesting is too deep to prove the target of a destructive tmux command")
        if not _mentions_tmux_or_kill(command):
            return ALLOW
        tokens = tokenize(command)
        if tokens is None:
            return self._unparsable(command)
        commands = segments(tokens)
        findings: list[str] = []
        for segment in commands:
            findings.extend(self._analyze_segment(segment, depth))
        for segment in commands:
            findings.extend(self._unexplained(segment))
        if findings:
            return Decision("ask", findings[0])
        return ALLOW

    def _unparsable(self, command: str) -> Decision:
        if _raw_destructive_evidence(command):
            return Decision(
                "ask",
                "could not parse the command, but it appears to contain a destructive "
                "tmux operation; refusing to authorize it",
            )
        return ALLOW

    # -- segment analysis --------------------------------------------------

    def _analyze_segment(self, words: list[Token], depth: int) -> list[str]:
        findings: list[str] = []
        for token in words:
            for sub in token.subs:
                decision = self.evaluate_text(sub, depth + 1)
                if decision.kind != "allow":
                    findings.append(decision.reason)
        i = 0
        while i < len(words) and _is_assignment(words[i].text):
            token = words[i]
            token.consumed = True
            value = token.text.split("=", 1)[1]
            if _raw_destructive_evidence(value):
                findings.append(VARIABLE_FINDING)
            i += 1
        if i >= len(words):
            return findings
        command = words[i]
        command.consumed = True
        base = os.path.basename(command.text)
        rest = words[i + 1:]
        if base == "tmux":
            findings.extend(self._analyze_tmux(rest, depth))
        elif base in ("kill", "pkill", "killall"):
            if _mentions_tmux(_tokens_text(words)):
                findings.append(
                    f"{base} by process name or command substitution may kill the "
                    "tmux server; refusing to authorize it without a human"
                )
            for token in rest:
                token.consumed = True
        elif base in SHELLS:
            findings.extend(self._analyze_shell(rest, depth))
        elif base == "eval":
            inner = " ".join(token.text for token in rest)
            for token in rest:
                token.consumed = True
            decision = self.evaluate_text(inner, depth + 1)
            if decision.kind != "allow":
                findings.append(decision.reason)
        elif base == "alias":
            for token in rest:
                token.consumed = True
                body = token.text.split("=", 1)[1] if _is_assignment(token.text) else token.text
                if _mentions_tmux_or_kill(body):
                    decision = self.evaluate_text(body, depth + 1)
                    if decision.kind != "allow":
                        findings.append(decision.reason)
        elif base in ("export", "local", "declare", "readonly", "typeset"):
            for token in rest:
                token.consumed = True
                if _is_assignment(token.text):
                    value = token.text.split("=", 1)[1]
                    if _raw_destructive_evidence(value):
                        findings.append(VARIABLE_FINDING)
        elif base in WRAPPERS:
            findings.extend(self._analyze_wrapped(base, rest, depth))
        return findings

    def _analyze_shell(self, rest: list[Token], depth: int) -> list[str]:
        for i, token in enumerate(rest):
            text = token.text
            if text == "-c" or (text.startswith("-") and "c" in text[1:] and not text.startswith("--")):
                if i + 1 >= len(rest):
                    return []
                inner = rest[i + 1]
                for token2 in rest[:i + 2]:
                    token2.consumed = True
                decision = self.evaluate_text(inner.text, depth + 1)
                if decision.kind != "allow":
                    return [decision.reason]
                return []
        return []

    def _analyze_wrapped(self, base: str, rest: list[Token], depth: int) -> list[str]:
        i = 0
        value_flags = WRAPPER_VALUE_FLAGS.get(base, ())
        while i < len(rest):
            text = rest[i].text
            if text == "--":
                i += 1
                break
            if text.startswith("-") and text != "-":
                flag, _, attached = text.partition("=")
                if not attached and flag in value_flags:
                    i += 2
                else:
                    i += 1
                continue
            if _is_assignment(text):
                i += 1
                continue
            break
        for token in rest[:i]:
            token.consumed = True
        if i >= len(rest):
            return []
        return self._analyze_segment(rest[i:], depth)

    # -- tmux invocation analysis -----------------------------------------

    def _analyze_tmux(self, words: list[Token], depth: int) -> list[str]:
        findings: list[str] = []
        i = 0
        socket_spec = None  # ("-S" | "-L", value)
        subcommand: Optional[Token] = None
        rest: list[Token] = []
        while i < len(words):
            token = words[i]
            token.consumed = True
            text = token.text
            if text == "--":
                i += 1
                continue
            if text.startswith("-") and text != "-":
                if text.startswith("-S") or text.startswith("-L"):
                    value, i = _take_flag_value(words, i, text[2:])
                    socket_spec = (text[:2], value)
                    continue
                if text.startswith("-c"):
                    # `tmux -c shell-command` executes a shell command.
                    value, i = _take_flag_value(words, i, text[2:])
                    decision = self.evaluate_text(value, depth + 1)
                    if decision.kind != "allow":
                        findings.append(decision.reason)
                    continue
                if text in ("-f", "-T"):
                    _, i = _take_flag_value(words, i, "")
                    continue
                i += 1
                continue
            subcommand = token
            rest = words[i + 1:]
            for token2 in rest:
                token2.consumed = True
            break
        if subcommand is None:
            return findings
        findings.extend(self._scan_tmux_commands(subcommand, rest, socket_spec, depth))
        return findings

    def _scan_tmux_commands(self, subcommand: Token, rest: list[Token],
                            socket_spec, depth: int) -> list[str]:
        r"""Decide whether a tmux invocation contains a guarded operation.

        Nested arguments are judged by their kind.  ``run-shell`` arguments are
        shell commands: they are judged on their own terms and are never
        authorized by the outer socket; only a ``\;`` command list in the same
        invocation is judged against the targeted socket.  ``if-shell``,
        ``bind-key`` and ``confirm-before`` arguments are tmux command lists
        for the targeted server, so a bare guarded word in them is authorized
        by an owned outer ``-S``.  Anything that names tmux is judged as a
        command of its own in every case.
        """
        findings: list[str] = []
        resolved = _tmux_word(subcommand.text)
        kind = resolved[0] if resolved else None

        if kind == "shell":
            # run-shell arguments are shell commands: arbitrary side effects are
            # never authorized by the outer socket, so nested findings are
            # propagated.  A `\;` command list after those arguments still runs
            # against the outer server and is judged with it.
            for token in rest:
                if token.text.startswith("-") or token.text == ";":
                    continue
                decision = self.evaluate_text(token.text, depth + 1)
                if decision.kind != "allow":
                    findings.append(decision.reason)
            guarded = self._guarded_in_words([subcommand] + _command_list_items(rest))
            if guarded is not None:
                findings.extend(self._authorize(guarded, socket_spec))
            return _dedupe(findings)

        if kind == "commands":
            for token in rest:
                if token.text.startswith("-"):
                    continue
                text = token.text
                decision = self.evaluate_text(text, depth + 1)
                if decision.kind != "allow":
                    findings.append(decision.reason)
                    continue
                if _mentions_tmux(text):
                    continue
                nested = self._guarded_in_words(tokenize(text) or [])
                if nested is not None:
                    findings.extend(self._authorize(nested, socket_spec))

        if _canonical_tmux_word(subcommand.text) == "detach-client":
            value = _flag_value(rest, "-E")
            if value is not None:
                decision = self.evaluate_text(value, depth + 1)
                if decision.kind != "allow":
                    findings.append(decision.reason)

        guarded = self._guarded_in_words([subcommand] + rest)
        if guarded is not None:
            findings.extend(self._authorize(guarded, socket_spec))
        return _dedupe(findings)

    def _authorize(self, guarded: str, socket_spec) -> list[str]:
        """Judge a guarded operation against the socket the invocation targets."""
        live = self.live[0]
        if socket_spec is None:
            return [
                f"destructive tmux operation ({guarded}) targets the live/default socket "
                f"({live}); run it through tmux-sandbox for a private server"
            ]
        flag, value = socket_spec
        if flag == "-L":
            return [
                f"destructive tmux operation ({guarded}) uses -L {value}, which cannot "
                "name an owned tmux-sandbox socket"
            ]
        target = canonicalize(value, self.cwd)
        if target in self.live:
            return [
                f"destructive tmux operation ({guarded}) targets the live socket ({target})"
            ]
        if owned_state_for_socket(target, self.tmpdir):
            return []
        return [
            f"destructive tmux operation ({guarded}) targets {target}, which is not an "
            f"owned tmux-sandbox socket (live socket: {live})"
        ]

    def _guarded_in_words(self, words: list[Token]) -> Optional[str]:
        flags = [token.text for token in words if token.text.startswith("-")]
        for token in words:
            name = _canonical_tmux_word(token.text)
            if name is None:
                continue
            if name in DESTRUCTIVE_FLAG_CHARS:
                if any("a" in flag[1:] or "P" in flag[1:] for flag in flags):
                    return name
                continue
            return name
        return None

    # -- evidence of operations the tokenizer could not attribute ----------

    def _unexplained(self, words: list[Token]) -> list[str]:
        dangerous = [
            token
            for token in words
            if not token.consumed and not token.quoted and _is_dangerous_token(token.text)
        ]
        if not dangerous:
            return []
        tmuxish = [
            token
            for token in words
            if not token.quoted and _mentions_tmux(_tokens_text([token]))
        ]
        for token in dangerous:
            if any(other is not token for other in tmuxish):
                return [
                    "could not prove the target of a tmux operation in this command; "
                    "refusing to authorize it without a human"
                ]
        return []


def _is_assignment(text: str) -> bool:
    if "=" not in text or text.startswith("="):
        return False
    name = text.split("=", 1)[0]
    return bool(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name))


def _mentions_tmux(text: str) -> bool:
    return bool(_TMUX_WORD_RE.search(text)) or "$TMUX" in text


def _tokens_text(tokens: list[Token]) -> str:
    return " ".join(
        " ".join([token.text, *token.subs]).strip() for token in tokens
    )


def _command_list_items(tokens: list[Token]) -> list[Token]:
    r"""Tokens after a tmux ``\;`` command separator, if one is present."""
    for i, token in enumerate(tokens):
        if token.text == ";":
            return tokens[i + 1:]
    return []


def _take_flag_value(words: list[Token], index: int, attached: str):
    """Value of a tmux ``-X value``/``-Xvalue`` flag, and the next index."""
    if attached:
        return attached, index + 1
    if index + 1 < len(words):
        words[index + 1].consumed = True
        return words[index + 1].text, index + 2
    return "", index + 1


def _flag_value(tokens: list[Token], flag: str) -> Optional[str]:
    """Value of a tmux flag given as ``-X value`` or ``-Xvalue``."""
    for i, token in enumerate(tokens):
        if token.text == flag:
            return tokens[i + 1].text if i + 1 < len(tokens) else ""
        if token.text.startswith(flag) and len(token.text) > len(flag):
            return token.text[len(flag):]
    return None


def _dedupe(reasons: list[str]) -> list[str]:
    out: list[str] = []
    for reason in reasons:
        if reason not in out:
            out.append(reason)
    return out


def _mentions_process_kill(text: str) -> bool:
    return bool(re.search(r"(?<![A-Za-z0-9_])(pkill|killall)(?![A-Za-z0-9_])", text))


def _mentions_tmux_or_kill(text: str) -> bool:
    return _mentions_tmux(text) or _mentions_process_kill(text)


def _tmux_word(word: str):
    """Resolve a tmux command word (exact, alias, or unique prefix).

    One-character words are always ambiguous in tmux, so only longer prefixes
    are treated as commands.
    """
    if not word:
        return None
    for name, entry in TMUX_COMMANDS.items():
        if word == name or (len(word) > 1 and name.startswith(word)):
            return entry
    return None


def _canonical_tmux_word(word: str) -> Optional[str]:
    """Resolve a guarded tmux command word to its canonical name."""
    entry = _tmux_word(word)
    return entry[1] if entry and entry[0] == "guarded" else None


def _is_dangerous_token(text: str) -> bool:
    base = os.path.basename(text)
    return base == "tmux" or _canonical_tmux_word(text) is not None


_TMUX_WORD_RE = re.compile(r"(?i)(?<![A-Za-z0-9_])tmux(?![A-Za-z0-9_])")
_RAW_GUARDED = re.compile(
    r"(?i)\b(kill[a-z-]*|source[a-z-]*|detach[a-z-]*|killw|killp|"
    r"run-shell|if-shell)\b"
)


def _raw_destructive_evidence(text: str) -> bool:
    """Textual fallback used only when tokenization fails or a wrapper hides a command."""
    return bool(_TMUX_WORD_RE.search(text) and _RAW_GUARDED.search(text))


# --------------------------------------------------------------------------
# public entry point
# --------------------------------------------------------------------------


def evaluate(command: str, *, cwd: str, env: Mapping[str, str],
             tmpdir: Optional[str] = None,
             live_sockets: Iterable[str] = ()) -> Decision:
    analyzer = _Analyzer(cwd, env, tmpdir, live_sockets)
    return analyzer.evaluate_text(command)

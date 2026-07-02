#!/usr/bin/env bash
# tmux-pi-sessions — status section listing OTHER sessions with a finished/
# needs-input agent, e.g. "[pi - build / tests]". The current session is never
# listed (its pane is highlighted by tmux-agent-indicator instead). A session
# drops off once it has been focused, and reappears when a new agent finishes.
#
# Requires bash 4+ (associative arrays). Reuses tmux-agent-indicator state:
#   TMUX_AGENT_PANE_<pane>_STATE=<state>   per-pane agent state
#   TMUX_AGENT_SESSION_SEEN_<session>=1    session acknowledged (focused)
set -euo pipefail
command -v tmux >/dev/null 2>&1 || exit 0
tmux display-message -p '#{session_name}' >/dev/null 2>&1 || exit 0

current="${1:-}"

opt() { local v; v=$(tmux show-option -gqv "$1" 2>/dev/null || true); [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"; }

ATTENTION_STATES=$(opt "@agent-indicator-session-dots-attention-states" "needs-input,done")
LABEL=$(opt "@pi-sessions-label" "pi")
COLOR=$(opt "@pi-sessions-color" "yellow")

declare -A want
IFS=',' read -ra arr <<< "$ATTENTION_STATES"
for s in "${arr[@]}"; do s="${s//[[:space:]]/}"; [ -n "$s" ] && want["$s"]=1; done

# Sessions that currently have at least one attention pane.
declare -A attn
while IFS= read -r line; do
    [ -z "$line" ] && continue
    pane_id="${line#TMUX_AGENT_PANE_}"; pane_id="${pane_id%%_STATE=*}"
    state="${line#*_STATE=}"
    [ -n "${want[$state]:-}" ] || continue
    session=$(tmux display-message -p -t "$pane_id" '#{session_name}' 2>/dev/null || true)
    [ -n "$session" ] && attn["$session"]=1
done < <(tmux show-environment -g 2>/dev/null | grep '^TMUX_AGENT_PANE_.*_STATE=' || true)

# Acknowledge the current session (you're looking at it) and drop stale SEEN
# markers so a fresh finish shows the session again.
[ -n "${attn[$current]:-}" ] && tmux set-environment -g "TMUX_AGENT_SESSION_SEEN_${current}" 1
while IFS= read -r line; do
    [ -z "$line" ] && continue
    s="${line#TMUX_AGENT_SESSION_SEEN_}"; s="${s%%=*}"
    [ -z "${attn[$s]:-}" ] && tmux set-environment -gu "TMUX_AGENT_SESSION_SEEN_${s}" 2>/dev/null || true
done < <(tmux show-environment -g 2>/dev/null | grep '^TMUX_AGENT_SESSION_SEEN_' || true)

# Render: attention sessions minus current minus already-seen, in list order.
names=()
while IFS= read -r session; do
    [ -z "$session" ] && continue
    [ "$session" = "$current" ] && continue
    [ -n "${attn[$session]:-}" ] || continue
    seen=$(tmux show-environment -g "TMUX_AGENT_SESSION_SEEN_${session}" 2>/dev/null | sed 's/^[^=]*=//' || true)
    [ "$seen" = "1" ] && continue
    names+=("$session")
done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)

[ ${#names[@]} -eq 0 ] && exit 0

out=""; sep=""
for n in "${names[@]}"; do out+="${sep}${n}"; sep=" / "; done
printf '#[fg=%s][%s - %s]#[default]' "$COLOR" "$LABEL" "$out"

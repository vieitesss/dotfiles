#!/usr/bin/env bash
# Create one git worktree + tmux pane per parallel task and launch pi in each.
# Usage: launch_panes.sh <base-branch> <worktree-root> <branch>=<abs-plan-path> [...]
# Each pane cd's into its worktree and runs pi with the plan attached.
set -euo pipefail

[ $# -ge 3 ] || { echo "usage: launch_panes.sh <base-branch> <worktree-root> <branch>=<plan> [...]" >&2; exit 2; }
[ -n "${TMUX:-}" ] || { echo "error: not inside a tmux session" >&2; exit 1; }

base="$1"; wt_root="$2"; shift 2
prompt="Implement the attached plan in this worktree on the current branch. Commit all your work on this branch when you are done."

mkdir -p "$wt_root"
for pair in "$@"; do
    branch="${pair%%=*}"; plan="${pair#*=}"
    [ -f "$plan" ] || { echo "error: plan not found: $plan" >&2; exit 1; }
    dir="$wt_root/$branch"

    git worktree add -b "$branch" "$dir" "$base"

    # New pane in the current window, cwd = worktree, then launch pi.
    pane=$(tmux split-window -P -F '#{pane_id}' -c "$dir")
    tmux send-keys -t "$pane" "pi @'$plan' '$prompt'" Enter
    tmux select-layout tiled >/dev/null
    echo "launched: branch=$branch pane=$pane dir=$dir plan=$plan"
done

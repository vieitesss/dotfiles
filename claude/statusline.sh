#!/usr/bin/env bash
# Claude Code status line mirroring the custom Pi footer defined in
# pi/agent/extensions/custom-footer.ts.
#
#   <tokens> · <context %> · <cost>        <cwd> · <branch>        <model> · <effort>
#
# Reads the Claude Code status line JSON on stdin. Requires bash and jq.
# Colors follow the Gruber theme Pi uses; on macOS they auto-switch with the
# system appearance. Override with CLAUDE_STATUS_THEME=light|dark.

set -u

input=$(cat)

mapfile -t fields < <(jq -r '
  (.workspace.current_dir // .cwd // ""),
  (.model.id // .model.display_name // "no-model"),
  (.cost.total_cost_usd // 0),
  (.context_window.total_input_tokens // ""),
  (.context_window.used_percentage // ""),
  (.effort.level // (if .thinking.enabled then "on" else "off" end))
' <<<"$input")
cwd=${fields[0]:-}
model=${fields[1]:-no-model}
cost=${fields[2]:-0}
tokens=${fields[3]:-}
percent=${fields[4]:-}
effort=${fields[5]:-off}

if [ -n "$cwd" ]; then
  branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)
else
  branch=''
fi

# --- formatting (mirrors custom-footer.ts) ----------------------------------
format_tokens() {
  local n=${1%.*}
  case $n in '' | *[!0-9]*) printf '?'; return ;; esac
  if [ "$n" -lt 1000 ]; then
    printf '%d' "$n"
  elif [ "$n" -lt 10000 ]; then
    local t=$(((n + 50) / 100))
    printf '%d.%dk' "$((t / 10))" "$((t % 10))"
  elif [ "$n" -lt 1000000 ]; then
    printf '%dk' "$(((n + 500) / 1000))"
  elif [ "$n" -lt 10000000 ]; then
    local t=$(((n + 50000) / 100000))
    printf '%d.%dM' "$((t / 10))" "$((t % 10))"
  else
    printf '%dM' "$(((n + 500000) / 1000000))"
  fi
}

format_cwd() {
  case $1 in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

tokens=$(format_tokens "$tokens")
if [ -z "$percent" ]; then
  percent='?'
else
  percent=$(printf '%.1f%%' "$percent")
fi
cost=$(printf '$%.2f' "$cost")
cwd=$(format_cwd "$cwd")
[ "${#branch}" -gt 30 ] && branch="${branch:0:29}…"

# --- colors -----------------------------------------------------------------
theme=${CLAUDE_STATUS_THEME:-}
if [ -z "$theme" ]; then
  case $(uname -s) in
    Darwin)
      if [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null)" = Dark ]; then
        theme=dark
      else
        theme=light
      fi
      ;;
    *) theme=light ;;
  esac
fi
if [ "$theme" = dark ]; then
  yellow='#ffdd33' dim='#565f73' # gruber-darker
else
  yellow='#cc9600' dim='#465169' # gruber-lighter
fi

fg() {
  local h=${1#\#}
  printf '\033[38;2;%d;%d;%dm' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"
}
reset=$'\033[0m'
sep=''           # U+F444, separator used by the Pi footer
fallback='' # U+EACC, fallback separator

sep_dim="$(fg "$dim")$sep$reset"
left="$(fg "$yellow")$tokens$reset $sep_dim $(fg "$dim")$percent$reset $sep_dim $(fg "$dim")$cost$reset"
middle="$(fg "$dim")$cwd$reset"
[ -n "$branch" ] && middle="$middle $sep_dim $(fg "$dim")$branch$reset"
right="$(fg "$dim")$model $sep $effort$reset"

# --- layout (mirrors custom-footer.ts) --------------------------------------
plain_left="$tokens $sep $percent $sep $cost"
plain_middle="$cwd${branch:+ $sep $branch}"
plain_right="$model $sep $effort"
# Claude Code passes the full terminal width but renders the line with a
# 2-column margin on each side, truncating anything wider with "…".
width=$((${COLUMNS:-0} - 4))
if [ "$width" -gt 0 ] 2>/dev/null; then
  free=$((width - ${#plain_left} - ${#plain_middle} - ${#plain_right}))
  if [ "$free" -ge 2 ]; then
    left_pad=$((free / 2))
    line="$left$(printf '%*s' "$left_pad" '')$middle$(printf '%*s' "$((free - left_pad))" '')$right"
  else
    line="$left $(fg "$dim")$fallback$reset $middle $right"
  fi
else
  line="$left $sep $middle $sep $right"
fi

printf '%s\n' "$line"

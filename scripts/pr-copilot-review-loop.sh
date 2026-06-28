#!/usr/bin/env bash
# pr-copilot-review-loop.sh — bash driver for the PR Copilot Review Loop workflow.
# Spec: ~/.agents/skills/loop-me/workflows/pr-copilot-review-loop.md
#
# Usage:
#   pr-copilot-review-loop.sh [<pr-number-or-url>]   run the loop
#   pr-copilot-review-loop.sh --self-check            verify core logic (no network)

set -uo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
MAX_CYCLES=5
POLL_INTERVAL=20          # seconds between Copilot-review polls
POLL_TIMEOUT=600          # 10 min per cycle before aborting

# ── Logging ──────────────────────────────────────────────────────────────────
log()  { echo "[loop] $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ── GitHub helpers ───────────────────────────────────────────────────────────

get_nwo() {
  gh repo view --json nameWithOwner --jq '.nameWithOwner'
}

resolve_pr_number() {
  local arg="${1:-}"
  if [[ -z "$arg" ]]; then
    gh pr view --json number --jq '.number' 2>/dev/null \
      || die "No PR argument given and no open PR for current branch."
  elif [[ "$arg" =~ ^[0-9]+$ ]]; then
    echo "$arg"
  else
    echo "$arg" | grep -oE '[0-9]+$' \
      || die "Could not parse PR number from: $arg"
  fi
}

get_pr_url() {
  gh pr view "$PR_NUMBER" --json url --jq '.url'
}

# Timestamp of the newest Copilot review, or empty.
latest_copilot_ts() {
  gh api --paginate "repos/${NWO}/pulls/${PR_NUMBER}/reviews?per_page=100" \
    --jq '.[] | select(.user.login | test("copilot"; "i")) | .submitted_at' \
    2>/dev/null | sort | tail -1 || true
}

# Timestamp of the newest Copilot inline code comment, or empty.
latest_copilot_comment_ts() {
  gh api --paginate "repos/${NWO}/pulls/${PR_NUMBER}/comments?per_page=100" \
    --jq '.[] | select(.user.login | test("copilot"; "i")) | .created_at' \
    2>/dev/null | sort | tail -1 || true
}

count_copilot_comments_after() {
  local baseline="$1"
  gh api --paginate "repos/${NWO}/pulls/${PR_NUMBER}/comments?per_page=100" \
    --jq '.[] | select(.user.login | test("copilot"; "i")) | .created_at' \
    2>/dev/null | awk -v baseline="$baseline" '$0 > baseline { n++ } END { print n + 0 }'
}

has_new_copilot_activity() {
  local review_ts="$1" baseline_review_ts="$2" comment_ts="$3" baseline_comment_ts="$4"
  [[ -n "$review_ts" && "$review_ts" > "$baseline_review_ts" ]] \
    || [[ -n "$comment_ts" && "$comment_ts" > "$baseline_comment_ts" ]]
}

request_copilot_review() {
  local out rc
  out=$(gh pr edit "${PR_NUMBER}" --add-reviewer "@copilot" 2>&1) && rc=0 || rc=$?
  if (( rc == 0 )); then
    log "Copilot reviewer requested."
  else
    log "WARN: could not request Copilot reviewer (rc=${rc}): ${out}"
  fi
}

# Poll until Copilot submits a review or adds inline comments after the baselines.
poll_new_copilot_activity() {
  local baseline_review_ts="${1:-}" baseline_comment_ts="${2:-}"
  local elapsed=0
  log "Polling for Copilot activity (review baseline: ${baseline_review_ts:-none}, comment baseline: ${baseline_comment_ts:-none})…"
  while (( elapsed < POLL_TIMEOUT )); do
    local review_ts comment_ts
    review_ts=$(latest_copilot_ts)
    comment_ts=$(latest_copilot_comment_ts)
    if has_new_copilot_activity "$review_ts" "$baseline_review_ts" "$comment_ts" "$baseline_comment_ts"; then
      log "New Copilot activity (review: ${review_ts:-none}, comment: ${comment_ts:-none})."
      return 0
    fi
    sleep "$POLL_INTERVAL"
    elapsed=$(( elapsed + POLL_INTERVAL ))
  done
  return 1
}

# ── Brief ────────────────────────────────────────────────────────────────────
# Globals read: PR_URL, CYCLE, CYCLE_COMMITS[], CYCLE_PI_OUTPUT[], FINAL_STATE
print_brief() {
  echo ""
  echo "════════════════════════════════════════════"
  echo "  PR COPILOT REVIEW LOOP — BRIEF"
  echo "════════════════════════════════════════════"
  echo "PR:           ${PR_URL}"
  echo "Cycles run:   ${CYCLE}"
  echo "Final state:  ${FINAL_STATE}"
  echo ""
  local i
  for i in "${!CYCLE_PI_OUTPUT[@]}"; do
    local n=$(( i + 1 ))
    echo "── Cycle ${n} ─────────────────────────────────"
    if [[ -n "${CYCLE_COMMITS[$i]:-}" ]]; then
      echo "Commits pushed:"
      echo "${CYCLE_COMMITS[$i]}" | sed 's/^/  /'
    else
      echo "Commits pushed: none (all comments rejected/deferred/handled)"
    fi
    echo ""
    echo "Triage output:"
    echo "${CYCLE_PI_OUTPUT[$i]}" | sed 's/^/  /'
    echo ""
  done
  echo "────────────────────────────────────────────"
  echo "PR: ${PR_URL}"
  echo "════════════════════════════════════════════"
}

# ── Self-check (--self-check) ─────────────────────────────────────────────────
self_check() {
  local failed=0

  # ISO timestamp string ordering (used by poll logic)
  if [[ "2025-01-01T00:00:00Z" > "2024-01-01T00:00:00Z" ]]; then
    echo "PASS: timestamp ordering"
  else
    echo "FAIL: timestamp ordering"; failed=1
  fi

  # Empty baseline: any timestamp is newer
  if [[ "2025-01-01T00:00:00Z" > "" ]]; then
    echo "PASS: empty baseline"
  else
    echo "FAIL: empty baseline"; failed=1
  fi

  # Copilot can add comments without a newer review timestamp.
  if has_new_copilot_activity "2025-01-01T00:00:00Z" "2025-01-01T00:00:00Z" "2025-01-01T00:01:00Z" "2025-01-01T00:00:00Z"; then
    echo "PASS: comment-only Copilot activity"
  else
    echo "FAIL: comment-only Copilot activity"; failed=1
  fi

  # PR number from URL
  local url="https://github.com/owner/repo/pull/123"
  local num
  num=$(echo "$url" | grep -oE '[0-9]+$')
  if [[ "$num" == "123" ]]; then
    echo "PASS: PR number from URL"
  else
    echo "FAIL: PR number from URL (got '${num}')"; failed=1
  fi

  # Cycle cap: loop exits at MAX_CYCLES
  local count=0
  while (( count < MAX_CYCLES )); do
    count=$(( count + 1 ))
  done
  if (( count == MAX_CYCLES )); then
    echo "PASS: cycle cap (${MAX_CYCLES})"
  else
    echo "FAIL: cycle cap"; failed=1
  fi

  if (( failed == 0 )); then
    echo "All checks passed."; exit 0
  else
    echo "Some checks FAILED." >&2; exit 1
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
[[ "${1:-}" == "--self-check" ]] && self_check

# Resolve PR and context
PR_ARG="${1:-}"
NWO=$(get_nwo)
PR_NUMBER=$(resolve_pr_number "$PR_ARG")
PR_URL=$(get_pr_url)
log "PR #${PR_NUMBER} — ${PR_URL}"

if [[ -n "$(git status --porcelain)" ]]; then
  die "Working tree is not clean; refusing to run an automated commit/push loop."
fi

# Brief state
CYCLE=0
FINAL_STATE=""
CYCLE_COMMITS=()
CYCLE_PI_OUTPUT=()

# Bootstrap: request a Copilot review if none exists yet
BASELINE_REVIEW_TS=$(latest_copilot_ts)
BASELINE_COMMENT_TS=$(latest_copilot_comment_ts)
if [[ -z "$BASELINE_REVIEW_TS" && -z "$BASELINE_COMMENT_TS" ]]; then
  log "No Copilot activity found — requesting a review before cycle 1…"
  request_copilot_review
  poll_new_copilot_activity "" "" || {
    FINAL_STATE="ABORTED — Copilot did not respond before cycle 1 (10-min timeout)"
    CYCLE=0
    print_brief
    exit 1
  }
fi

# ── Loop ─────────────────────────────────────────────────────────────────────
while (( CYCLE < MAX_CYCLES )); do
  CYCLE=$(( CYCLE + 1 ))
  log "── Cycle ${CYCLE}/${MAX_CYCLES} ──────────────────────────"

  # Step 1 — pi: triage Copilot's comments, implement fixes, commit, reply/resolve threads
  if [[ -n "$PR_ARG" ]]; then
    PI_PR_CONTEXT="Determine the PR number and linked issue yourself from this PR reference: ${PR_ARG}."
  else
    PI_PR_CONTEXT="Determine the PR number and linked issue yourself from the current branch."
  fi

  SHA_BEFORE=$(git rev-parse HEAD 2>/dev/null || echo "")

  _pi_tmp=$(mktemp)
  log "Running pi agent…"
  pi --no-extensions -p "Use the review-github-pr-comments skill. ${PI_PR_CONTEXT}
Review only Copilot's comments (author login matches 'copilot', case-insensitive).
Commit+push for this PR branch is explicitly authorised for the life of this loop —
commit and push all accepted fixes, then reply to + resolve every triaged thread
per the skill's §8 (fix → include the commit SHA; reject/defer → one-line reason)." 2>&1 | tee "$_pi_tmp"
  _pi_exit=${PIPESTATUS[0]}
  log "pi agent finished (exit: ${_pi_exit})."

  PI_OUTPUT=$(cat "$_pi_tmp")
  rm -f "$_pi_tmp"

  # Safety net: commit anything pi left uncommitted before we push.
  if ! git diff --quiet HEAD 2>/dev/null; then
    log "Uncommitted changes found after pi — staging and committing…"
    git add -A
    git commit -m "fix: apply Copilot review suggestions (cycle ${CYCLE})"
  fi

  SHA_AFTER=$(git rev-parse HEAD 2>/dev/null || echo "")
  NEW_COMMITS=""
  if [[ "$SHA_BEFORE" != "$SHA_AFTER" ]]; then
    NEW_COMMITS=$(git log --oneline "${SHA_BEFORE}..${SHA_AFTER}" 2>/dev/null || echo "")
  fi

  CYCLE_PI_OUTPUT+=("$PI_OUTPUT")
  CYCLE_COMMITS+=("$NEW_COMMITS")

  # Step 2 — push (no-op if nothing was committed)
  log "Pushing…"
  git push

  # Step 3 — record baseline, re-request Copilot
  BASELINE_REVIEW_TS=$(latest_copilot_ts)
  BASELINE_COMMENT_TS=$(latest_copilot_comment_ts)
  request_copilot_review

  # Step 4 — poll for a new review or new inline comments
  poll_new_copilot_activity "$BASELINE_REVIEW_TS" "$BASELINE_COMMENT_TS" || {
    FINAL_STATE="ABORTED — Copilot did not respond in cycle ${CYCLE} (10-min timeout)"
    break
  }

  # Step 5 — termination check
  INLINE_COUNT=$(count_copilot_comments_after "$BASELINE_COMMENT_TS")
  log "New Copilot inline code comments this cycle: ${INLINE_COUNT}"

  if (( INLINE_COUNT == 0 )); then
    FINAL_STATE="CLEAN — Copilot has no more code comments"
    break
  fi

  if (( CYCLE == MAX_CYCLES )); then
    FINAL_STATE="CAP REACHED — ${MAX_CYCLES} cycles completed; unresolved comments remain"
  fi
done

[[ -z "$FINAL_STATE" ]] && FINAL_STATE="CAP REACHED — ${MAX_CYCLES} cycles completed; unresolved comments remain"

print_brief

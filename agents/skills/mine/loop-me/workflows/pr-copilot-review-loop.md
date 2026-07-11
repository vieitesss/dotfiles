# Workflow: PR Copilot Review Loop

> Spec complete. Implementable.

## Loop
The recurring pattern: a PR is open; Copilot reviews it; comments must be
triaged, addressed, committed, pushed; Copilot re-reviews; repeat until Copilot
has nothing more to say about the code.

## Trigger
**Manual start** of a single long-running run, scoped to one named PR. The run
loops internally: triage → commit → push → re-request → poll until Copilot's
review lands → repeat. No webhook/event infrastructure. (Decided: shape A.)

## Vehicle
**A bash driver script** (no sandcastle, no new deps). The script owns
deterministic plumbing; `pi` is invoked only for judgment.

- **bash + gh own:** cycle counting, commit, push, re-request Copilot, polling
  for the new review, termination check, assembling the brief.
- **pi (one invocation per cycle) owns:** triage + implement accepted comments
  via `review-github-pr-comments` (which itself uses `commit-changes`/`coding`).

## Run (one cycle)
1. `pi` runs `review-github-pr-comments` on the PR: triage Copilot's comments
   against the linked issue + diff (fix / reject / defer / handled), implement
   the accepted fixes, commit via `commit-changes`, and **reply to + resolve**
   each triaged thread per that skill's §8 (fix → commit SHA; reject/defer →
   one-line reason). Standing commit+push approval makes §8 apply every cycle.
2. bash: `git push`.
3. bash: re-request Copilot as reviewer (`gh api .../requested_reviewers`).
4. bash: poll `gh` until Copilot posts a new review (see wait policy).
5. bash: termination check — clean review or cap=5 → stop; else go to 1.

## Checkpoint
**One, at the end (push-right).** Launching the workflow on a named PR is the
standing, scoped commit/push approval for that branch for the life of the loop;
the agent commits and pushes each cycle without asking. When the loop
terminates, the user gets a single brief and decides what's next. No mid-loop
checkpoints.

## Brief (end-of-loop)
Presented once when the loop terminates:
- cycles run; final state (clean / hit cap).
- per cycle: what Copilot flagged → fix / reject / defer / handled (+ one-line why).
- final commit SHAs pushed.
- link down to the PR.

## Termination
**Primary:** Copilot's latest review has zero actionable inline code comments
(a bare "looks good" summary doesn't count) → stop, success.

**Backstop:** hard cap of **5 cycles** → stop, report unresolved in brief.

No "identical review" guard — if Copilot repeats the same comments the loop keeps
going until it either converges to a clean review or hits the 5-cycle cap.

## Wait policy (step 4)
Before re-requesting (step 3), record the latest Copilot review's `submitted_at`.
Poll for a Copilot review newer than that timestamp.
- **Interval:** 20s.
- **Max wait per cycle:** 10 min, then **abort + brief** ("Copilot didn't respond
  in cycle N"). Silence is never treated as a clean review.

## Launch
`<script> <pr-number-or-url>`; if omitted, infer the PR from the current branch.
- **Linked issue:** auto-discovered from the PR body closing keyword
  (`Closes #N` / `Fixes #N`), passed to triage as context; if none, proceed and
  note it in the brief.
- **First cycle:** triage existing Copilot comments. If no Copilot review exists
  yet at launch, request one and wait (wait policy) before cycle 1.

## Implementer notes (mechanics to verify, not user decisions)
- **Identify Copilot reviews:** filter reviews/threads by the Copilot bot author
  (login `Copilot`, app `copilot-pull-request-reviewer[bot]`) — confirm against
  `gh api repos/{o}/{r}/pulls/{n}/reviews` on a live PR.
- **"Actionable inline code comments":** count inline review comments attached to
  Copilot's newest review (`.../reviews/{id}/comments`). >0 = has code comments;
  a review with body-only summary and 0 inline comments = clean.
- **Re-request Copilot:** `gh api -X POST repos/{o}/{r}/pulls/{n}/requested_reviewers`
  with the Copilot reviewer — confirm exact payload on a live PR.
- **No new commits in a cycle** (all rejected): `git push` is a no-op; still
  re-request Copilot and continue — the loop relies on Copilot converging.

## Resolved decisions
1. Trigger → internal loop, single long-running run (A).
2. Vehicle → bash driver; no sandcastle, no new deps.
3. Poll mechanics → baseline `submitted_at`; 20s interval / 10min cap / abort on timeout.
4. "Code comment" → actionable inline review comments; summary-only = clean.
5. Autonomy → fully autonomous commit+push in-loop; one end-of-loop checkpoint.
6. Cap → 5 cycles; no identical-review guard.
7. Threads → reply + resolve every cycle per `review-github-pr-comments` §8.
8. Launch → PR arg or infer from branch; auto-discover linked issue; first cycle
   triages existing comments (request a review first if none exist).

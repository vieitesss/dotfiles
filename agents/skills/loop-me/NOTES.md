# NOTES — the user's world

Raw notes on tools, channels, and terminology. Sharpen fuzzy terms into canonical ones here.

## Tools / platforms
- **GitHub** — PRs, issues, reviews. `gh` CLI available.
- **Copilot** — used as an automated PR *reviewer* (GitHub Copilot code review).
- **pi** — the coding agent harness this runs in. Has skills:
  - `review-github-pr-comments` — fetch + triage PR comments (fix/reject/defer/handled), implement accepted ones.
  - `commit-changes` — conventional one-line atomic commits.
- **sandcastle** (`~/opt/sandcastle`) — TS toolkit orchestrating AI agents in sandboxes, iteration loops. Candidate implementation vehicle; user wonders if something simpler suffices.

## Terminology (to canonicalize during grilling)
- "trigger" — TBD: who/what starts a run.
- "Copilot comments about code" — the termination signal lives here. Need a crisp definition of "code comment" vs noise.

## Open tensions
- ~~Global AGENTS.md forbids autonomous commit/push.~~ RESOLVED: launching this
  workflow on a named PR is explicit, scoped standing approval to commit+push on
  that branch for the life of the loop. No per-cycle prompts.

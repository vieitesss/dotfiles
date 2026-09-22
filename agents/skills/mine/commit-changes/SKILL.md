---
name: commit-changes
description: Create conventional, one-line commits from current git changes, splitting work into the smallest sensible atomic commits. Use when the user asks to commit changes.
---

# Commit changes

Inspect repo state, split changes into the smallest atomic groups by intent, and
commit each group with a one-line Conventional Commit message. After staging a
group and drafting its message, run the guard on the current staged diff. You
write every message; the guard only judges the draft.

## Rules

- Run this workflow only after an explicit user request to commit the changes
  already discussed. That approval is **one-use**: if the working tree changed
  after the request, a commit was blocked, cancelled, or rejected, or the next
  commit would include anything not covered, ask again. Honor git-write guards,
  hooks, aliases, and prompts; do not bypass them. Do not infer permission from
  "finish", "save", "apply", "ship", or "clean up". A guard verdict is not
  permission.
- Push only when the user explicitly requests a push.
- Conventional Commits: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`
  — scope optional.
- One logical change per commit. Split independent fixes, features, docs, tests,
  and refactors; combine only when tightly coupled. You own grouping from the
  diffs.
- One-line messages only (no body).
- Do not add yourself as co-author.
- Leave secrets and sensitive files unstaged (`.env`, keys, credentials). The
  guard's local pattern screen is a backstop, not exhaustive detection.

## Workflow

1. Run `git status`, `git diff`, and recent `git log`.
   Done when every change is named and the recent message style is known.
2. Partition remaining changes into the smallest safe atomic groups.
   Done when every relevant path is in one group or explicitly skipped.
3. For each group:
   1. Stage only that group's paths.
   2. Draft a one-line Conventional Commit message.
   3. From the git repository, run the guard so it reads the current index
      (`git diff --cached`):

      ```bash
      node <skill-dir>/scripts/guard.mjs --message "<drafted one-line message>"
      ```

      `<skill-dir>` is this skill's directory. First run, or if `node_modules` is
      missing: `npm install` in `<skill-dir>/scripts`, then rerun the guard.
      Credential: `TYPESAFE_API_KEY` in the environment (never print it). For this
      process, leave `TYPESAFE_LOG_LEVEL` unset (unset it if it is already
      `debug`) so the SDK stays at default `warn` — `debug` logs request bodies,
      including the diff. Leave `--diff-file` and `--stdin` off; those are for
      manual checks. `--help` lists flags and exit codes.
   4. Follow **Verdicts** below. `git commit` only when the verdict is `ok` or
      the run is **visibly unverified**, and the one-use approval still covers
      this group.
4. Repeat step 3 until every relevant group is committed or reported skipped.
5. Show `git status` and summarize commits, naming any **visibly unverified**
   or skipped groups.

## Verdicts

Exit `0` prints `ok`, `revise`, or `uncertain` from `message_matches`.
`commit_type` is advisory only — keep the verdict; you may adopt its prefix when
the output says confidence ≥ 0.8. Oversized staged diffs are clipped at a
48000-character heuristic (not a guaranteed token fit). A clipped diff is
never `ok`.

- **`ok`** — `message_matches` ≥ 0.70 and the staged diff was not clipped.
  Commit if approval still holds.
- **`revise`** — `message_matches` ≤ 0.30, including when the staged diff was
  clipped. Rewrite the message yourself (same staged diff) and rerun the guard.
  At most two rewrites, then stop and report this group uncommitted.
- **`uncertain`** — match above 0.30 but not `ok`.
  - **clipped** — evidence is incomplete. Stop and report this group; leave the
    drafted message as-is.
  - **not clipped** — `message_matches` between 0.30 and 0.70. Same two-rewrite
    cap as `revise`, then stop and report this group uncommitted.
- **exit 3** (no `TYPESAFE_API_KEY`) or **exit 4** (every Jev call failed,
  including SDK/API errors) — **visibly unverified**. Continue with your drafted
  message and say so in the step-5 summary. Missing `node`, or `npm install`
  that cannot run, is the same path. If the script did not run, the local secret
  screen did not run either — keep leaving secrets unstaged.
- **exit 6 `blocked_secrets`** — the local screen found a likely secret. Nothing
  was transmitted. Do not commit this group. Pause and report the findings; wait
  for explicit safe handling. Unstage or redact only under existing explicit
  approval for that remediation — never as an automatic bypass of the block.
- **exit 2** (could not read the diff) or **exit 5** (invalid arguments) — fix
  staging or the command and rerun. Not unverified.

A clean screen does not mean the diff is free of secrets.

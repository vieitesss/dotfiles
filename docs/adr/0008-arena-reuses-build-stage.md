# Arena reuses the Build Stage

When a Work Item admits several valid shapes or is a one-way door, the Manager
can run an Arena through the `arena` skill without adding a Stage or a launcher
flag. Each candidate is an ordinary `subagent launch --stage build` call with a
distinct `--item`, a distinct `--harness`, and its own worktree cut from the
same diff base. After the candidates finish, the Manager launches one read-only
ad-hoc judge (omitting `--stage`, as [ADR 0007](0007-bash-launcher-rex-only.md)
allows) on a vendor no candidate used to score every candidate against the
rubric. The Manager picks a base and launches a fresh Build Subagent to graft
the strongest parts of the losing candidates onto that base.

[ADR 0006](0006-manager-always-delegates.md) still holds. The Manager writes the
brief and rubric, coordinates launches, and picks the base, while every code
edit runs in a Build Subagent. [ADR 0003](0003-subagent-is-a-stage-instance.md)
still holds. Every candidate and the graft are standard Build Stage instances
that inherit the Stage table's Build skills and Verdict contract.

## Considered options

- **Add an `arena` Stage to the launcher.** The launcher would own candidate
  fan-out, rubric handling, judge dispatch, and graft orchestration behind
  `subagent launch --stage arena`. Rejected: Arena is a Manager procedure over
  existing Build and ad-hoc launches, not a single Subagent prompt. Adding a
  Stage would duplicate Build's skills in the Stage table, push orchestration
  logic into the bash launcher, and hide individual candidates from the
  Manager's Ledger and per-Subagent follow-up loop.

## Consequences

- `agents/skills/subagents/scripts/subagent` needs no new Stage, flag, or
  fan-out code for Arena.
- Candidates automatically get every Build rule, including `tdd`, `coding`,
  `principles`, and the closing Verdict, and the graft goes through normal
  Review before merge.
- The Manager owns staggering launches, tracking candidate worktrees in the
  Ledger, and cleaning up losing worktrees once the graft lands.

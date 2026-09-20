# Issue 0003: Jev routing in pi-subagent

**Skill:** `~/.agents/skills/mine/pi-subagent/SKILL.md`
**Pattern:** model routing / harness engineering. Small fast judgments at the delegation boundary, before any expensive session is spawned.

## Problem

The supervisor classifies each user task ad hoc: which kind (research/implement/write), trivial vs. multi-step (arc or plain `start`), and how to parse free-text child reports (PASS vs. FIX). Each misclassification spawns the wrong session profile or skips the reviewer gate.

## Proposed Jev judgments

| ID | Type | Question | State |
|---|---|---|---|
| `task_kind` | Choice | research / implement / write — what kind is this task? | user request + repo context |
| `needs_arc` | Noul | Is this a multi-step implementation (plan→work→critique) or trivial? | user request |
| `review_verdict` | Choice | PASS / FIX / unclear — what is this reviewer reply saying? | reviewer completion report |
| `escalation_kind` | Choice | need_decision / interview_request / progress — what does this child message need? | escalation text |

`review_verdict` replaces fragile string matching on free-text reviewer reports.

## Integration shape

A small router script the supervisor calls before spawning: request in, `task_kind` + `needs_arc` out, mapping onto the skill's session table. Report parsing becomes a Jev call instead of regex/prefix checks. Note the pi-subagent skill is also where model routing policy lives (`/update-subagents`), so this issue pairs naturally with it.

## Open questions

- Latency budget: the router adds a hop before every spawn — measure against the ~150ms claim.
- How much repo context does `task_kind` need to be reliable?
- Fallback behavior when Jev confidence is low: default to implementer + reviewer (the safest profile)?

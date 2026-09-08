---
name: update-subagents
description: Retarget the model profile for one subagent kind.
disable-model-invocation: true
argument-hint: "use <model> [effort] to <research|implement|write|review>"
---

# Update subagents

Retarget one kind so the **next spawn** of that kind uses the new profile. Running sessions stay as they are.

Resolve sibling `../pi-subagent/SKILL.md` (the table) and `../pi-subagent/scripts/pi-subagent.sh` (helper constants) relative to this `SKILL.md`.

## 1. Parse

Expect `/update-subagents use <model> [effort] to <research|implement|write|review>`.

- Missing model, or kind not exactly `research` | `implement` | `write` | `review`: refuse and say so. Do not guess.
- Effort omitted: keep that kind's current effort.

This step is complete when the model and kind are valid, or the user has been told why it was refused.

## 2. Map

| Kind | Table row (Session) | Helper constants |
|---|---|---|
| research | researcher | none |
| implement | implementer | `DEFAULT_MODEL` / `DEFAULT_EFFORT` |
| write | writer | none |
| review | reviewer | `CRITIC_MODEL` / `CRITIC_EFFORT` |

This step is complete when the row and constants for this kind are identified.

## 3. Edit

1. In the table, set that row's Model cell to the given model. Set Effort only when the user passed one; otherwise leave the cell as-is.
2. When the kind has helper constants, write them as **literals** (`CRITIC_MODEL=...`, not `$PLANNER_MODEL`). Match the table: new model, and the effort cell after step 1.
3. Leave the planner row, `PLANNER_*`, `DEFAULT_AGENT`, and every other kind untouched. Do not edit `.pi-subagent-runs/` or stop running children.

This step is complete when the next spawn of that kind would use the new profile, and running sessions are untouched.

# Issue 0004: Jev parsing and project mapping in clockify-fill

**Skill:** `~/.agents/skills/mine/clockify-fill/SKILL.md`
**Pattern:** route-and-fill. Replace brittle keyword tables with classification; make repo→project mapping consistent across runs.

## Problem

Step 2.5 parses Google Chat messages with a hardcoded keyword table ("buenas" → login, "paro a comer" → lunch, …). Any rewording, typo, or emoji silently breaks work-hour detection. Step 3 maps repos to Clockify projects ad hoc — the agent re-derives the mapping every run, so identical repos can land on different projects between weeks.

## Proposed Jev judgments

| ID | Type | Question | State |
|---|---|---|---|
| `work_event` | Choice | start-of-day / lunch-start / lunch-end / end-of-day / none — what does this message announce? | one chat message (+ sender, timestamp) |
| `relative_event` | Choice | same event set — what event is the user reporting conversationally? | user message in conversation |
| `project` | Choice | Which Clockify project does this work item belong to? | repo name, PR/issue titles, project list from `clockify-cli project list` |
| `same_work_item` | Noul (pairwise) | Do these two activities (commit/PR/issue) belong to the same work item? | pair of activity records |

`project` can be run once per repo and cached — the mapping is stable, so re-inference per run is waste.

## Integration shape

A parsing script between step 2.5 and step 3: chat messages in, typed work-event timeline out, plus a cached repo→project mapping table. The skill keeps its rounding rules, preview table, and confirmation checkpoint unchanged — Jev only hardens the input parsing and mapping.

## Open questions

- Confidence handling for ambiguous chat messages: default to `none` (skip) or flag for the user?
- Where does the repo→project cache live, and how is it invalidated when projects change?
- Conversational relative-time parsing still needs the duration arithmetic in code — Jev only classifies the event; confirm that split.

---
name: lightweight-development-workflow
description: Lightweight personal development workflow for repos using `CONTEXT.md` and ADRs instead of SDD specs. Use after `workflow-router` selects lightweight mode for feature work, complex fixes, refactors, or design-heavy changes.
---

# Lightweight Development Workflow

Use `/context-modeling`, `/grilling`, `/codebase-design`, and `/tdd`.

## Flow

1. Read repo instructions, `CONTEXT.md`, and `docs/adr/` if present.
2. Grill only missing/risky decisions. Ask one question at a time.
3. As design choices crystallize, update `CONTEXT.md` or write ADRs via `/context-modeling`.
4. Before coding, give one proceed gate:
   - goal
   - chosen design
   - ADRs written/updated
   - public interface/seam
   - behaviors to test
   - validation commands
5. After approval, use `/tdd`:
   - one failing test
   - minimal code
   - repeat
   - refactor only while green
6. Closeout:
   - run scoped tests/lint
   - self-review diff for simplification, duplication, unnecessary abstractions
   - summarize changed code/docs and validation

If new ambiguity appears during coding, stop, update docs if it is a design choice, then ask before continuing.

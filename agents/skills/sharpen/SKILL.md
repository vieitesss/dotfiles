---
name: sharpen
description: "Rewrite a user prompt into a deeper, more rigorous prompt without executing it. Use for /sharpen, 'sharpen this prompt', or 'make this prompt deeper'."
---

# Sharpen

Rewrite the user's prompt into a deeper version of the same task, not a bigger one. Return only the rewritten prompt; stop immediately and leave the task itself unexecuted.

## 1. Deepen silently

Work through four questions before writing, and fold their answers into the rewritten prompt rather than printing them:

1. **Professional bar**: what would a top practitioner in this field add here that the prompt omits?
2. **Rawest material**: what primary, undigested inputs should the work start from instead of summaries?
3. **Methods and tools**: which concrete techniques, measurements, or tools fit this job?
4. **Outside check**: what independent signal — neither you nor the user — proves the result is right?

## 2. Rewrite

Draft a single ready-to-run prompt that asks for exactly what those four answers define:

- Keep the original scope fixed while raising rigor and depth.
- Ask the executing agent to prototype any choice an experiment can settle and recommend an option from what it observed.
- Leave product or preference choices that no experiment can settle for the user to decide.

## Output

Emit the rewritten prompt alone: no preamble, no analysis breakdown, no commentary, and no execution of the task.

---

*Adapted from pstack (`skills/sharpen/SKILL.md`), Copyright (c) 2026 Lauren Tan, MIT License.*

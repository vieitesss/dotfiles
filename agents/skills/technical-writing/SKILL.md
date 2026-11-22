---
name: technical-writing
description: Technical writing standard for human-facing docs. Use when writing or reviewing READMEs, PR bodies, guides, reference pages, changelogs, or commit messages.
---

# Technical writing

Apply this standard to human-facing docs: READMEs, PR bodies, guides, reference pages, changelogs, and commit messages. For agent-facing docs (skills, `AGENTS.md`, `CLAUDE.md`), follow `writing-for-agents` instead.

Write so a tired engineer understands on the first read. Use real symbol, file, flag, and command names. Cut every word that does no work. When a rule makes a sentence worse, rewrite the sentence another way or keep the clearer phrasing.

## 1. Pick the Diátaxis mode

Choose one mode per page and commit to it before drafting. When a page needs a second mode, split it and link across.

- **Tutorial (learning by doing):** State what the reader will build. Give every step a visible result and state what to expect. Keep explanation to one clause plus a link.
- **How-to (steps to a goal):** Solve a specific problem for a competent reader. Write actions only, allow branches, and name the page by the task.
- **Reference (facts for lookup):** Describe accurately, completely, and neutrally. Mirror the structure of the thing described.
- **Explanation (understanding and why):** Cover one bounded topic with context, design decisions, constraints, and alternatives. State a viewpoint here and nowhere else.

PR bodies, changelogs, and commit messages skip Diátaxis and apply steps 2 to 4 directly. Keep a PR body readable in under a minute; link raw logs, SHA lists, and metric tables instead of pasting them.

## 2. Draft in Google developer style

- Address the reader as "you" in present tense.
- Use active voice and name the actor; use passive only when the actor is unknown or beside the point.
- Write instructions as imperative commands. Put the condition or warning before the step, and put the common case first.
- Write concrete, specific claims ("a column rename fails the build", not "schema changes cause issues"). Vary sentence length so prose breathes.
- Use sentence-case headings that carry the point, one `h1` per page, and consecutive heading levels.
- Use numbered lists for sequences and bullets for unordered sets. Introduce each list with a complete sentence and keep items parallel.
- Put code in code font and UI elements in bold. Use serial commas, write descriptive link text, and spell out lists instead of ending with "etc.".
- Keep tone plain and direct: skip filler, buzzwords, "please", and minimizers ("simply", "easy", "quickly") in procedures.

## 3. Tighten with ASD-STE100 and clarity rules

Apply these mechanical constraints to every sentence:

- One instruction per sentence, under ~20 words. One thought per sentence elsewhere, under ~25 words.
- One term per concept and one verb per action across the entire document.
- Keep articles ("a", "the"), verbs, and structural words ("that") intact; avoid "-ing" constructions when a direct verb works.
- Place modifiers ("only", "not") directly beside the word they modify, and break up long noun strings.
- Give every pronoun ("it", "they", "this", "which") one unambiguous noun antecedent, never a whole clause.
- End thoughts with periods rather than semicolons, em dashes, or slashes; avoid "(s)". Make parentheticals grammatically complete.
- Verify every file path, count, and tree claim against the current commit, and include the regenerating command when a claim can drift.

## 4. Run an unslop pass

Read [`../unslop/SKILL.md`](../unslop/SKILL.md) and apply every rule to remove AI vocabulary, filler, hedging, and formatting tells.

Done when: the page holds a single Diátaxis mode (where applicable), every rule in steps 2 and 3 holds, and the `unslop` pass leaves no remaining tells.

---

*Adapted from pstack (`skills/technical-writing/SKILL.md`), Copyright (c) 2026 Lauren Tan, MIT License.*

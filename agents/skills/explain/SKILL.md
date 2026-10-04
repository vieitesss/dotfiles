---
name: explain
description: Explain a concept as a one-page visual HTML explainer.
disable-model-invocation: true
argument-hint: "What concept should I explain?"
---

# Explain a concept with one HTML page

Concept to explain: `$ARGUMENTS`

If it is empty, ask the user which concept to explain and stop.

You write only the **draft** (extended Markdown). The `am` CLI owns layout, colours, dark mode, and diagram coordinates. Write every visual as a component; reach for raw HTML / CSS / SVG only when no component can express it.

`am` means the CLI bundled with this skill (single file, Node.js 20+, no install):

```bash
node "${CLAUDE_SKILL_DIR}/scripts/am.mjs"
```

If `${CLAUDE_SKILL_DIR}` is not substituted, use the absolute path of the directory holding this SKILL.md.

## 1. Workflow

1. Ground the concept. When it lives in the current codebase, read the code first; otherwise rely on what you know and flag anything uncertain. Every fact on the page is checked against a source.
2. Plan 3–8 panels. Each panel answers one sub-question.
3. Pick a component per panel by the shape of its information (section 3).
4. Render in one Bash call with a heredoc:

````bash
node "${CLAUDE_SKILL_DIR}/scripts/am.mjs" render - <<'AM_EOF'
---
title: Title
---
## A Panel title
```flow
A -> B: label
```
AM_EOF
````

5. Read the output:
   - `✓ <path>`: success. The browser opens per the user's `am config`; `--no-open` affects this run only.
   - `✗ L<line> [component] …` plus a correct example: fix that line as shown and render again.
   - `STE n warnings`: rewrite the flagged lines as suggested and render again. Retry at most 2 rounds; if warnings remain, keep the page and say so.
6. Reply in the terminal with 2–3 lines: the core takeaway and the page path. The draft and the HTML stay out of the reply.

## 2. Draft format

```markdown
---
template: sheet     # sheet: one-screen board (default) | doc: linear walkthrough
theme: blueprint    # blueprint: drafting-sheet look (default) | shadcn: card look
title: Title
subtitle: One-line summary     # optional
cols: 3             # sheet columns, default 3; panels span with span / rows
source: RFC 9293    # any other key shows in the header meta row
---
Intro: the core takeaway in one or two sentences (optional).

## A Panel title {span=2 meta="small top-right text"}
Plain Markdown: paragraphs, lists, tables, quotes.
Table status words ok / no / warn (optionally with text: "ok approved") → ✓ / ✗ / ! badges.

## B {bare}            ← bare: no title bar (suits a kv title block)
```

- Panel letter IDs are optional; they are assigned automatically.
- ```html / ```svg fenced blocks embed verbatim — the last resort.
- Full format: `am help format`. Component syntax: `am help <component>`. Component list: `am list`. The CLI's help text is in Chinese.

## 3. Pick components by information shape

| Information shape | Component | Minimal syntax |
|---|---|---|
| What connects to what, architecture, decision branches | `flow [LR]` | `A -> B: label`, `A --> C` dashed, `A -> B & C` fan-out, `{decision?}` `(start)` `[(database)]`, `*highlight`, `group name: A, B` |
| Messages between participants over time | `sequence [num]` | `A -> B: request`, `B --> A: response`, `note A, B: text`, `== phase ==` |
| Hierarchy / directories / taxonomy | `tree [list]` | indentation sets depth, `label \| description`, `` `id` label `` |
| History / phases | `timeline [v]` | `when \| title \| description`, `*` highlights |
| Values against limits | `limits` | `label \| 13 / 20 \| unit`, limit only: `label \| max 20` |
| Word-by-word annotation of a sentence | `annot` | `# heading \| right note`, `[fragment]{note}`, `[wrong]{!red note}`, `> footnote` |
| Metadata / title block | `kv [cols=2]` | `key: value`, `* wide cell: value` |
| Takeaway / warning | `callout <info\|ok\|warn\|err> Title` | Markdown body |
| Multi-dimension comparison, can / can't list | Markdown table | status column with ok / no / warn |

Layout rules:
- Lead with the takeaway. The intro or first panel gives the core answer; later panels give the evidence.
- One panel, one question. Past 8 panels, cut or split into a second page.
- Give the densest panel more width with `span`; monospace sentences (`annot`) get at least `span=2`.
- Use real numbers only. Without real data, pick another component than `limits`; label illustrative data "illustrative".

## 4. STE controlled writing (text in the draft)

`am render` checks the draft and warns by default (`style: 80`); `style: strict` refuses to render below the bar; `style: off` disables it.

- One sentence, one idea.
- Active voice. Steps are imperatives ("Close the valve", not "The valve should be closed").
- One term per meaning. Name a thing the same way across the page.
- Sentence length: steps (ordered lists) at most 20 words; descriptions at most 25 words.
- At most 6 sentences per paragraph. Use lists for complex content.
- Common short words: use, start, before (over utilize, commence, prior to).
- Mark deliberate bad examples with `~~strikethrough~~` or put them in a table row with status `no`; the checker skips them.

---
name: component-finder
description: Find UI elements styled inconsistently across web pages and recommend one shared style for each element kind.
disable-model-invocation: true
---

# Component Finder

Find cross-page visual inconsistencies without changing the repository. The goal is one coherent visual language across the web application.

## 1. Map the UI

Read repository instructions, `CONTEXT.md`, and relevant ADRs when present. Identify every first-party page and route, then inspect its rendered elements, components, usage sites, styles, tests, and stories or examples. Exclude generated, vendored, and dependency code.

Inventory the element kinds on each page: buttons, radio controls, pickers, cards, fields, dialogs, navigation, tables, and project-specific equivalents. Trace imports and usage sites; a definition alone does not reveal where or how it appears.

**Complete when:** every first-party page and its element kinds are listed and inspected.

## 2. Compare element kinds across pages

Group elements that serve the same UI role even when their markup, component source, or styling differs. A candidate needs at least two pages using the same element kind with inconsistent styles—for example, radio controls, pickers, cards, or buttons that look unrelated.

Compare typography, color, spacing, shape, borders, elevation, icons, and hover, focus, active, selected, disabled, loading, error, and responsive states. Also compare semantics, keyboard behavior, screen-reader behavior, and tests where applicable.

Visual similarity between unrelated element kinds is not a candidate. Keep variants only when they communicate a meaningful interaction, hierarchy, or state. For nested matches, report the smallest useful shared style target; report an enclosing component only when it is a distinct consistency opportunity.

**Complete when:** every repeated element kind has either a cross-page style candidate or a concrete reason its styles should remain distinct.

## 3. Recommend one shared style

Choose the strongest existing style using, in order: accessibility, design-system alignment, complete interaction states, readability, adaptability, tests, and existing adoption. Popularity, age, or brevity alone do not make a style canonical.

For each element kind:

- Name the canonical style and every page or implementation that should adopt it.
- Show the current visual differences and which canonical values replace them.
- Describe the minimal shared style contract: tokens, states, layout rules, and legitimate variants.
- Identify the narrowest reuse mechanism already supported by the codebase: existing component, theme, style primitive, or shared class.
- Reject unification when one style would erase meaningful interaction, hierarchy, or state differences.
- Rate it `Strong`, `Worth exploring`, or `Speculative`.

Rank candidates by page coverage, inconsistency visibility, divergence risk, and maintenance savings.

**Complete when:** each candidate has one canonical style, affected pages, a bounded style contract, evidence, risks, and a recommendation strength.

## 4. Report and stop

Read [HTML-REPORT.md](HTML-REPORT.md), then write a timestamped HTML report to the OS temporary directory: `$TMPDIR`, falling back to `/tmp` on Unix or `%TEMP%` on Windows. Open it with `open`, `xdg-open`, or `start`, and give the user its absolute path.

The repository is read-only throughout this skill. Produce no refactor, source edit, ADR, or follow-up workflow. If no candidates survive, report that result and the inspected pages.

**Complete when:** the report opens, its path is shown, and no repository file was changed.

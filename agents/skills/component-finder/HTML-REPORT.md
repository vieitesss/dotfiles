# Component Finder HTML Report

Create one static HTML file. Use Tailwind via CDN for layout and Mermaid 11 via CDN only when relationships are graph-shaped. Keep code excerpts HTML-escaped. Use screenshots only when they already exist and require no application startup.

## Scaffold

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Component finder — {{repo}}</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script type="module">
      import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
      mermaid.initialize({ startOnLoad: true, theme: "neutral", securityLevel: "loose" });
    </script>
  </head>
  <body class="bg-stone-50 text-slate-900">
    <main class="mx-auto max-w-6xl space-y-12 px-6 py-12">
      <header>...</header>
      <section id="candidates" class="space-y-10">...</section>
      <section id="top-recommendation">...</section>
    </main>
  </body>
</html>
```

## Header

Show repository name, date, inspected pages, and a compact legend for the three recommendation strengths. Start with evidence; omit introductory prose.

## Candidate card

Render one `<article>` per candidate with:

- Element kind and recommendation badge: `Strong`, `Worth exploring`, or `Speculative`
- Every affected page
- Exact file paths and line ranges
- Compact, HTML-escaped excerpts
- Current visual differences across pages
- Canonical existing style and why it is strongest
- Canonical typography, color, spacing, shape, borders, elevation, icons, and interaction states
- Minimal shared style contract: tokens, states, layout rules, and legitimate variants
- Narrowest existing reuse mechanism
- Accessibility and test evidence
- Benefits and risks
- Current/proposed visual

Keep prose compact and evidence specific. Do not assign invented numeric scores.

## Visuals

Put each page's current element beside the proposed shared style. Use HTML/CSS mockups for visual comparisons and Mermaid only for import or usage graphs. Existing screenshots may supplement evidence but never replace code and behavior analysis.

Show convergence on one visual language, not new implementation code:

```text
Current pages                         Proposed shared style
Checkout Card   Profile Card          Canonical Card
square, grey    rounded, shadow   →   one shape, spacing, color, and state set
```

## Ranking and ending

Order cards by page coverage, inconsistency visibility, divergence risk, and maintenance savings. End with one **Top recommendation** card containing the element kind and one sentence explaining why it should be unified first.

When no candidates survive, replace candidate and recommendation sections with:

- Inspected pages
- Element kinds kept distinct and concrete reasons
- A clear “No consolidation candidates found” result

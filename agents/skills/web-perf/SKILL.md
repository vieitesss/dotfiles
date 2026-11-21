---
name: web-perf
description: >
  Keep web front-end code fast on a 4× slower mobile CPU. Use when writing or
  editing UI, CSS animations, DOM handlers, fonts, SVGs, or page loading, and
  when auditing or optimizing website performance.
---

# Web performance guard

Target a **4× phone** (mid-range mobile device with a 4× slower CPU than a laptop), judged at p75 real visits.

## Workflow

1. **Before writing:** choose the cheapest platform technique for the effect. Consult [`RULES.md`](RULES.md) for the domain you are touching (animation, layout, input, loading, CLS, fonts, SVG, JS, memory).
2. **While writing:** stay **compositor-only**, **draw once, move cheap**, and batch reads before writes. Document any deliberate trade-off in a one-line comment at the site.
3. **After writing (or on an audit):** run the candidate scan in [`AUDIT.md`](AUDIT.md) on touched files (or `blog/src/blog/` for a full audit). Triage every **candidate** in context before dismissing or fixing it.
4. **When changing animations or input handlers:** measure before and after under 4× CPU throttling using [`VERIFY.md`](VERIFY.md). If measurement cannot run, state why and what to check on a real device.
5. **Report and fix:** apply the bar below. For violations outside your edited block, report them instead of making unrelated edits.

Done means: every touched file scanned, every **candidate** triaged, every 🔴 and 🟠 issue fixed or proposed, and every motion or input change measured (or explicitly marked unmeasured).

## Budgets

- **Frame:** ≤ 16.7 ms (60 Hz), ≤ 8.3 ms (120 Hz)
- **Main-thread task:** ≤ 50 ms
- **INP:** ≤ 200 ms · **LCP:** ≤ 2.5 s · **CLS:** ≤ 0.1

## Core invariants

- **Compositor-only motion:** animate `transform` and `opacity` via CSS transitions/animations or WAAPI (`el.animate()`, `reverse()`, `playbackRate = -1`).
- **Draw once, move cheap:** pre-render shadows, blurs, masks, and textures onto static layers or tiles; animate their `transform` or `opacity`.
- **Batch reads, then writes:** read all layout geometry before mutating styles; cache with `ResizeObserver` and track visibility with `IntersectionObserver`.
- **Feedback first, yield long work:** paint the UI response before heavy work, and yield tasks exceeding 50 ms.
- **Stable above-the-fold:** give media explicit dimensions, prioritize the LCP resource (`fetchpriority="high"`), and keep the initial view readable before JS runs.

## Reporting and fixing

Report each confirmed issue with:

- **Severity:** 🔴 user-visible now (jank, slow load, layout shift) · 🟠 hits slower devices or larger content · 🟢 hygiene
- **Where:** `file:line`
- **What and why:** one line naming the pipeline stage or metric hurt (for example, `animates clip-path → repaint every frame`)
- **Fix:** concrete replacement

Fix 🔴 and 🟠 issues directly unless the fix changes visuals or behaviour; in that case propose it and ask first. Skip cold-path micro-optimizations (a one-off `getBoundingClientRect()` on click is fine; the same call inside `scroll` is not). When an expensive visual effect is genuinely required, keep it cheap: small area, drawn once, short duration, `prefers-reduced-motion` fallback, and a comment noting the trade-off.

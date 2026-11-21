# Verification under 4× CPU throttling

Measure before and after any animation or input-handler change. Compare relative numbers; headless Chromium is not a real phone GPU, so report what you measured and ask the user to confirm on a real device when it matters.

## CDP trace with existing repo tools (Node 22+ and Chromium)

Uses only Node's built-in `WebSocket` and `chromium` (no Playwright or extra dependencies).

Start an isolated Preview (or reuse one from `verify-sb`) so you never touch the author's port 8000 or Live site, then run [`scripts/trace.mjs`](scripts/trace.mjs):

```bash
node .agents/skills/web-perf/scripts/trace.mjs <url> <css-selector> [duration-ms]
```

What it does:

1. Launches an isolated headless `chromium` with a disposable profile and ephemeral CDP port, then cleans up both on exit.
2. Emulates a mobile viewport (`390×780`, DPR 3, touch) and applies `Emulation.setCPUThrottlingRate` (`rate: 4`).
3. Loads `<url>`, waits for `<css-selector>`, starts a `devtools.timeline` trace, clicks `<css-selector>`, and samples `requestAnimationFrame` deltas plus `PerformanceObserver` `longtask` entries for `duration-ms` (default `1500`).
4. Prints `Layout`, `Paint`, `UpdateLayoutTree`, and `RasterTask` event counts/durations alongside frame `p95_ms`, `over_20ms`, and `longTasks`.

## Interpreting results

- **Compositor-only animation:** near-zero `Layout` and `Paint` events during motion. Repeated `Paint`, `RasterTask`, or `Layout` events indicate a non-compositor property is animating.
- **Frame timing:** `p95_ms` well above 16.7 or multiple `over_20ms` frames under 4× throttling predicts stutter on mobile.
- **Long tasks:** flag any `longTasks` entry over 50 ms during interaction.
- **Full-page metrics:** when `lighthouse` is already installed, run `lighthouse <URL> --preset=perf --form-factor=mobile` for lab LCP/CLS/TBT; use CrUX/PageSpeed Insights for live field p75. Do not install packages without asking.

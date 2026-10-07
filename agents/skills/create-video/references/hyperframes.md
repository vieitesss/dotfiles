# Hyperframes adapter

Real HTML/CSS/JS composed on a timeline: HTML with `data-*` timing and one paused GSAP timeline, captured frame by frame in headless Chrome, encoded by FFmpeg. Needs Node ≥22 and FFmpeg. Commands below are checked against Hyperframes 0.8.140; confirm with `npx hyperframes --version` and `<command> --help`, and follow the installed version where they differ.

## Availability

1. `npx --no-install hyperframes --version`. A "missing packages" failure means the CLI is not installed; `npx hyperframes ...` would download it on first use, so ask for approval and name that command.
2. `npx hyperframes doctor --json` reports missing Node, FFmpeg or browser pieces; `npx hyperframes browser ensure` fetches the headless browser. Hand every missing piece to the user as an approval request.

## Guides

Five domain guides carry the evolving API. Load by role, directly:

| Guide | Role |
|---|---|
| `hyperframes-core` | composition contract: structure, `data-*` timing, tracks, determinism. Read before writing HTML |
| `hyperframes-animation` | motion rules, scene blueprints, transitions, runtimes (GSAP default) |
| `hyperframes-creative` | palettes, typography, composition patterns, brand decisions |
| `hyperframes-keyframes` | punch-ins, zooms, camera moves, 3D, SVG draw/morph, `keyframes` diagnostics |
| `hyperframes-cli` | command contracts: `init`, `check`, `snapshot`, `preview`, `render` |

Resolution order: installed guides → official guides at the tag matching the installed version → a user-approved setup (`npx hyperframes skills --help` lists how the CLI installs and updates guides). Official sources: repository <https://github.com/heygen-com/hyperframes>, guides in <https://github.com/heygen-com/hyperframes/tree/main/skills> (`<guide>/SKILL.md`; switch the branch to the tag matching `--version`). The entry skill `hyperframes` runs its own intent interview; skip it, because `composition-brief.md` already answers it.

## Compose

Working directories: scaffold from the output root, then `cd composition` for every other `npx hyperframes` command below (`lint`, `check`, `snapshot`, `preview`, `render`, `timeline`); outputs go back to the output root with `../`. A command given an explicit project path may run from anywhere.

1. Scaffold into `composition/`: `npx hyperframes init composition --non-interactive` (`--help` lists templates, `--video`, `--audio`). A website source can be captured with `npx hyperframes capture <url>` when `--help` confirms it; `catalog --query` and `add` pull ready-made blocks.
2. Build to the brief with the guides' rules. The ones that break renders:
   - Root `data-duration`, `data-width`, `data-height` set from the plan; length comes from the root.
   - One paused timeline registered at `window.__timelines["<root data-composition-id>"]`, registered after the build finishes; build inside `document.fonts.ready` when measuring text.
   - Seek-safe motion only: every value derives from timeline time, seeded random and local files; `repeat: -1` only under a finite root duration; animate a child of a `.clip`, because the framework owns `.clip` visibility (`display`, `visibility` and `autoAlpha` tweens fail lint).
   - Named fonts get `@font-face` to local files; media, fonts and images live as files under `composition/` and load by relative path, so the render has no network dependency.
   - Every `<audio>` has an `id` (otherwise silent), no `crossorigin` on media, unique element ids, unique `data-track-index` per overlapping audio.
3. Placed audio follows [`audio.md`](audio.md); copy each file from `../work/audio/` into project-local `assets/audio/` (inside the current `composition/` directory) so it loads by relative path. The `hyperframes-audio` guide covers mixing placed tracks. With voice, set the root duration to the narration length plus about 0.5 s.

## Gates

1. `npx hyperframes lint` while iterating (fast). An error here makes `check` report "0 samples", which means nothing ran; fix lint first.
2. `npx hyperframes check --json > ../work/check.json` is the build gate: runtime errors, failed requests, layout, WCAG contrast, motion assertions, with fix hints. Useful switches: `--snapshots`, `--samples N`, `--at t1,t2`, `--at-transitions`, `--strict`. Confirm with `check --help`.
3. Stills for Step 5: `npx hyperframes snapshot --at t1,t2,...` (scenes) and `check --at-transitions` or `snapshot` at mid-transition times. `snapshot --zoom` inspects small text. These commands print where they wrote each PNG (or take an output option when `--help` lists one); copy every PNG into `../work/stills/` and read the copies.
4. `npx hyperframes preview --background` is optional and non-blocking; `render` does not wait for it.

**Build gate:** `check` exits successfully with zero errors and the stills sit in `../work/stills/`. Any remaining warnings are explained in `../work/` with stills showing why they are harmless.

## Render and sync

From `composition/`:

```bash
npx hyperframes render --quality draft --output ../work/draft.mp4   # iterate
npx hyperframes render --quality delivery --output ../video.mp4     # final
```

Quality names differ across versions (`draft|looks|delivery` in 0.8.140; older text says `draft|standard|high`); `render --help` is authoritative.

Return to the output root for the Step 5 probe and cue check. Resolved timeline for the duration gate: `npx hyperframes timeline --json` (from `composition/`). Placement check: the placed audio `data-start` values equal the plan's cue times; this shows placement only, and the Step 5 cue check covers sync. Beat claims follow the measured-beats rule in [`audio.md`](audio.md).

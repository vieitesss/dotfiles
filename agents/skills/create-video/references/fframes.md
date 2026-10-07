# fframes adapter

A Rust library: each frame is a pure function `render_frame(frame, ctx) -> Svgr` returning an SVG tree built with `svgr!`; scenes split the timeline, `timeline!` and springs animate values, an `AudioMap` places sound, FFmpeg encodes. The Skia GPU backend (Metal on macOS, Vulkan elsewhere) is the default and gives the real-time preview. fframes has no DOM, HTML or React; it embeds images and video frames only. Commands below are checked against the official `fframes-video` skill; confirm with `cargo fframes --help` and `<project command> --help`.

## Availability

1. `cargo --version` and `cargo fframes --help` (the generator is the `cargo-fframes` crate).
2. Missing pieces are approval requests, each stated with its exact command:
   - Rust from <https://rustup.rs>.
   - System libraries FFmpeg is built with (macOS: `brew install pkg-config ffmpeg x264 x265 opus nasm ninja`; Linux and Windows steps are in the fframes README).
   - `cargo install --locked cargo-fframes`.
3. The first `cargo build --release` takes about 1 minute with prebuilt Skia and up to about 20 minutes when Skia compiles from source. Start it in the background right after scaffolding and write the composition while it runs. Build failures map to a missing system library or `LIBCLANG_PATH`; the upstream guide's Troubleshooting section lists the known ones.

## Guides

The official guide is `skills/fframes-video` (`SKILL.md` plus `references/api.md`, `design.md`, `audio.md`). Resolution order: installed `fframes-video` guide → the same files fetched at the tag or commit matching the `cargo-fframes` version → a user-approved setup. Official sources: repository <https://github.com/dmtrKovalenko/fframes>, README <https://github.com/dmtrKovalenko/fframes/blob/main/README.md>, guide <https://github.com/dmtrKovalenko/fframes/tree/main/skills/fframes-video>. Read `design.md` before designing and `api.md` while writing code.

## Scaffold

Run from the output root, and always pass `--yes`. The command below is the landscape default; substitute `--format` and `--template` from the plan's canvas:

```bash
cargo fframes new composition --template multi-scene --format landscape --fps 30 --yes
```

| Plan format | `--format` | Canvas |
|---|---|---|
| landscape (default) | `landscape` | 1920x1080 |
| vertical | `portrait` | 1080x1920 |
| square | `square` | 1080x1080 |
| uhd, only on request | `uhd` | 4K |

- `multi-scene` accepts only `landscape` and `uhd`; use it for landscape with several scenes.
- `single-scene` adapts to every format; use it for vertical, square or a one-scene video.
- A vertical or square video with several scenes starts from `single-scene` and gains scenes in code (`Scenes::from(vec![...])`, see `api.md`); a `multi-scene` landscape project is not retargeted by editing its constants.

The template is placeholder code; replace its layout, colors and fonts with the brief's design.

## Compose

After scaffolding, `cd composition` (the Cargo project root): every `R` command below runs there, and outputs go back to the output root with `../`. Zsh does not word-split a `R="cargo run --release --"` variable; define `R() { cargo run --release -- "$@"; }` and run every project command through it. Keep `--release`.

- One scene per idea. Starting points for promos and motion graphics: scenes 2–6 s, entrances 300–600 ms, exits 200–300 ms, stagger 60–120 ms. The reading floor in `SKILL.md` decides how long copy holds, whatever the amount.
- 1920x1080: titles 96–140 px, body 44–60 px, margins 8–10%, at most about 8 words per line. Portrait keeps content inside the middle 80%.
- Fonts live in `media/` and are referenced by family name with a numeric `font-weight`; embedded footage and screenshots are media files there too, and audio files from `../work/audio/` are copied into the project (see `api.md`).
- `render_frame` runs on many threads for every frame: no file reads, heavy work or panics inside it.
- Time every sound effect from the constants that drive the animation. Music, SFX and voice come from [`audio.md`](audio.md) and are placed with `AudioTrack` (`gain_db`, `fade_in`, `fade_out`, `duck_under_voice`, `.voice()`). Embedded audio is mono; use runtime `MediaDirectory` when stereo matters (see the upstream audio guide).

## Gates

Time addressing: `Intro@1.2s`, `Intro@end`, `50%`, `#3`, `a..b`. `--json` writes results to stdout.

1. `R timeline --json > ../work/timeline.json`: scenes, frame and second ranges, audio tracks, with overlaps resolved; check structure, pacing and the resolved duration first.
2. `R inspect --fail-on warning --json > ../work/inspect.json`: exits 2 on errors. It catches canvas cutoff, missing fonts, images and glyphs, invalid SVG and panics. It does not catch text overflowing its own box or WCAG contrast, so visual QA is required. A warning on a scene's first frames is usually an entrance: confirm it with a strip, and record the confirmed warnings in `../work/`.
3. Stills land in `../work/stills/`:
   - `R strip <scene> -n 12 && mv strip.png ../work/stills/<scene>-strip.png` for every scene (`strip` and `onion` write into the current directory, so move each file right after its run).
   - `R frame Intro@end,Outro@50% -o ../work/stills` full-size for key frames (typography, alignment, contrast).
   - `R onion "Intro@0..Intro@1s" -n 6 && mv onion.png ../work/stills/Intro-onion.png` for easing and stagger.
   - Mid-transition frames cover each overlap.
4. **With audio planned:** `R audio analyze --waveform ../work/waveform.png` shows per-scene levels and unintended silence; the loudness gate for the final file is in [`audio.md`](audio.md). A silent video skips this step.
5. `R preview` blocks, so it is optional: run it in the background or hand the command to the user. The browser WASM editor (Node and `wasm-pack`) is optional.

**Build gate:** steps 1–3 pass (and step 4 with audio), with their evidence in `../work/`.

## Render and sync

From `composition/`:

```bash
R render Intro --draft -o ../work/draft.mp4   # half-resolution scene draft
R render -o ../video.mp4                      # final
```

Return to the output root for the Step 5 probe and cue check. Resolved timeline for the duration gate: `R timeline` (from `composition/`). Placement check: `R audio at <cue time>` names the sound playing at each planned cue and `R timeline` shows the audio tracks; this shows placement only, and the Step 5 cue check covers sync. Beat claims follow the measured-beats rule in [`audio.md`](audio.md).

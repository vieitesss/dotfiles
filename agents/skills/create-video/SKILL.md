---
name: create-video
description: Create a video (promo, launch, explainer, demo, motion graphics, social clip) from a repo, URL or plain brief, rendered with Hyperframes or fframes. Use for /create-video, "make a video", "turn this into a video", "launch video".
argument-hint: "[project path | website URL | brief] [--renderer auto|hyperframes|fframes] [--format landscape|vertical|square] [--duration s] [--tone t] [--title t] [--voice] [--no-music] [--no-sfx]"
---

# /create-video

One flow, two renderers: input → storyboard → renderer → composition → proof → delivery. Every step ends on a **gate**; the step is done when its gate holds.

## Invocation

Flags may also arrive as plain language.

| Flag | Meaning |
|---|---|
| `--renderer auto\|hyperframes\|fframes` | `auto` (default) routes by content, see Step 3 |
| `--format landscape\|vertical\|square` | 1920x1080 (default), 1080x1920, 1080x1080 |
| `--duration <s>` | seconds; see Defaults |
| `--tone <name or freeform>` | presets: `default`, `polished`, `deadpan`, `cinematic`, `chaotic`, `app-store`, `yc-parody` (launch only) |
| `--title <text>` | on-screen title or product name |
| `--voice` | opt-in narration, see [`references/audio.md`](references/audio.md) |
| `--no-music`, `--no-sfx` | omit that layer entirely |

**Defaults:** 30 fps. Launch and social promos run about 20 s (15–25 s). Other videos get their duration from the content; ask once when it is unclear.

**Launch preset** (promos, "brag about this"): Hook → Reveal → Highlights → Punchline. The closing beat is a CTA, result, logo or payoff; a parody outro is a tone choice (`yc-parody`) only.

**Existing composition** (an HTML root with `data-composition-id`, or a Cargo project depending on `fframes`): keep its engine and edit a copy under `composition/`. Migrate engines only on request.

## Step 1: Understand

Resolve goal, audience, format, duration and tone from the input; ask only about what the input cannot answer.

- **Repo:** read the real UI: routes, components, styles, fonts, logos, copy.
- **URL:** fetch it; render it in a browser when the page is JS-built or reveals content on scroll.
- **Brief only:** a motion video with no product UI is valid; the brief's own statements are the source facts.
- Keep real copy and claims verbatim; metrics and testimonials come from the source or stay out.

**Gate:** a source-facts list (quotable copy and claims with their origin, asset files, screens and flows) exists, and every claim the video will make traces to it.

## Step 2: Storyboard

Create the output directory in the project (cwd for URL or brief input) and enter it; this is the **output root**:

```bash
OUT=video-output
[ -e "$OUT" ] && OUT=$(mktemp -d "video-output-$(date +%Y%m%d-%H%M%S)-XXXXXX")
mkdir -p "$OUT/work/stills" "$OUT/work/audio" && cd "$OUT"
```

```
video-output[-timestamp]/
  video-plan.md  composition-brief.md  video.mp4  poster.jpg  share-copy.txt
  composition/   renderer project (the adapter's scaffold creates it)
  work/          intermediates: scripts, audio, stills, probe output, captures
```

Paths in this skill are relative to the output root. Renderer commands run inside `composition/` (the adapters say so) and write outputs back with `../`; the ffmpeg and ffprobe commands in Steps 5–6 and in [`references/audio.md`](references/audio.md) run from the output root.

Write `video-plan.md`: goal, audience, format, duration, fps, tone, a one-sentence **creative angle**, scenes (time range, on-screen text, motion), source facts, audio plan (layers, provenance and license of each file, voice or none), poster beat.

Creative laws: **show the thing** (every frozen frame is postable on its own); **readable beats flashy**; product-in-use flows move (cursor, typing, state change) instead of standing still; the hook lands in the first 2 s.

**Reading floor:** a text line stays settled (whole line visible, motion done) for about 0.3 s per word, and a short label for about 0.8 s. Motion and cuts create the pace; the floor decides how long copy holds.

**Gate:** the resolved duration equals the target (scene lengths minus transition overlaps where scenes overlap); every text line meets the reading floor; every on-screen string comes from the source facts or is authored copy marked as such; the audio plan names provenance and license for every file; with `--voice`, the narration source is a supplied recording or a TTS confirmed available (otherwise ask now).

## Step 3: Choose the renderer

| Content | Renderer |
|---|---|
| real HTML/CSS, web UI, site or app flows, captured pages | Hyperframes |
| SVG geometry, typography, shaders, charts, many deterministic variants | fframes |

- An existing composition fixes the renderer; the brief records that as the reason.
- **One renderer per composition.** Mixed content goes to Hyperframes; fframes embeds footage or screenshots only, and those are footage, not native UI.
- An explicit `--renderer` is respected. Forcing fframes onto a web UI means the brief states the limits: screenshots or rebuilt SVG, no live DOM or CSS.
- No renderer is assumed faster; benchmark the target scene if speed decides.
- An unavailable engine gets an actionable setup request (exact commands, approval asked); the run waits for it, and any engine switch is announced and approved first.

Write `composition-brief.md` once: renderer and the reason, canvas, per-scene build notes, assets and fonts, cue times, known limits. The brief is the single creative interview: skip each engine's own intake or routing skill and load its domain guides directly (via the reference).

**Gate:** the brief names the renderer, the reason, and its limits.

## Step 4: Compose

Read the chosen adapter and follow it: [`references/hyperframes.md`](references/hyperframes.md) or [`references/fframes.md`](references/fframes.md). Source or generate audio per [`references/audio.md`](references/audio.md) before timing the scenes that depend on it.

Guides: use the installed official domain guides when present; otherwise fetch the official guide matching the installed tool version; otherwise ask the user to approve setup. Confirm evolving commands with the tool's `--help` and version output.

**Gate:** the adapter's build gate passes (named in the adapter).

## Step 5: Prove

Name the gate in force per renderer; the two differ (Hyperframes `check` covers contrast and layout, fframes `inspect` covers canvas cutoff, not text-box overflow or WCAG, so read the stills).

1. Capture stills at every scene and every transition (mid-transition included) into `work/stills/` (the adapter names the commands and the copy step); read each at full size; fix and recapture until clean.
2. Render the final MP4 to `video.mp4` in the output root.
3. Probe it from the output root and compare its duration with the renderer's resolved timeline:
   ```bash
   ffprobe -v error -show_entries stream=codec_type,width,height,r_frame_rate,nb_frames,duration -of default=nw=1 video.mp4
   ```
4. **With audio planned:** run the loudness gate in [`references/audio.md`](references/audio.md), then check sync. Planned start times and matching durations show placement only. For each of 1–3 key cues (hook hit, reveal, punchline) at time `T`, extract the waveform around it and the frame at it:
   ```bash
   ffmpeg -v error -y -ss <T-0.5> -t 1 -i video.mp4 -filter_complex "[0:a]showwavespic=s=1200x240[w]" -map "[w]" -frames:v 1 work/cue-<T>-wave.png
   ffmpeg -v error -y -ss <T> -i video.mp4 -frames:v 1 work/cue-<T>-frame.png
   ```
   Read both: the frame shows the visible event landing and the waveform onset sits near the image centre (within 10% of the width, 0.1 s). A cue that misses is fixed and re-rendered. A cue that cannot be observed is reported as unobserved and the user is invited to watch or listen to the video; "verified" is reserved for observed cues.
   A silent video is valid: with no audio planned, skip this item.

**Gate:** width x height and fps match the format; the duration matches the renderer's resolved timeline and the plan within 0.1 s; an audio stream exists exactly when audio was planned; stills for all scenes and transitions sit in `work/stills/` and were read; with audio, loudness holds and each key cue is observed in sync or reported honestly as unobserved. Evidence stays in `work/`.

## Step 6: Deliver

- **Poster:** pick the strongest settled beat (text fully in, before its exit) and extract it:
  ```bash
  ffmpeg -ss 3.2 -i video.mp4 -frames:v 1 -q:v 2 poster.jpg
  ```
  A frame on a fade or mid-transition gets nudged a few tenths and re-extracted.
- **Frame-0 bake:** offer it for social promos and apply it only on a yes. It swaps frame 0 for the poster, with same duration and audio untouched. Platforms may still choose another thumbnail:
  ```bash
  ffmpeg -y -i video.mp4 -i poster.jpg \
    -filter_complex "[0:v][1:v]overlay=0:0:enable='eq(n,0)'[v]" \
    -map "[v]" -map 0:a? -c:v libx264 -crf 18 -preset slow -pix_fmt yuv420p \
    -c:a copy -movflags +faststart video.baked.mp4 && mv video.baked.mp4 video.mp4
  ```
  Re-run the Step 5 probe after the bake.
- **`share-copy.txt`:** 1–3 sentences, specific to this video, tone-matched. A shareable video gets a postable caption; any other video gets a short contextual description (what it shows, where it fits).
- **Preserve** scripts, stills, probe output and intermediates in `work/`.

Tell the user: the creative angle in one sentence, the file paths, and an offer to reroll (a different tone or angle). Deliver `video.mp4` through the environment's configured attachment mechanism: in Telegram that is the attachment tool, because paths alone do not deliver there; with no bridge, the local paths are the delivery.

**Gate:** every file in the layout exists, the final probe passed, and the summary reached the user with `video.mp4` attached wherever an attachment mechanism exists.

## Guardrails

- Run browsers and source code only on inputs the user pointed at, with access they authorized; no login or paywall bypass.
- Installs, downloads (renderer deps, TTS models) and system packages follow user approval.
- Output goes to the new directory; existing user files stay unmodified.

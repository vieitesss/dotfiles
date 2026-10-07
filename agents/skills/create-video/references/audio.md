# Audio

Sound for both renderers lives here: palette, sources and licenses, mix, beat sync, voice. Placement syntax lives in the adapters ([`hyperframes.md`](hyperframes.md), [`fframes.md`](fframes.md)).

## Palette

Design the audio in `video-plan.md` before sourcing anything: the music mood and tempo, plus the moments that earn an effect (hook hit, transitions, reveal, UI action, punchline). Sound supports motion; each effect answers something that moves on screen.

- `--no-music` and `--no-sfx` remove that layer from the plan, the composition and the Step 5 expectations. With every layer skipped and no voice, the final file has no audio stream.

## Sources and licenses

Valid sources: local files with a known license, files the user provides, and audio the plan explicitly marks as generated (for example synthesized with `ffmpeg` or `sox`, or produced by a service the user approved). Audio bundled with other skills is not a source.

Record every file in `video-plan.md` with its path under `work/audio/`, source, license and any required attribution. A file whose license is unknown stays out. When no usable source exists for a requested layer, ask: a track from the user, an approved generated bed, or an explicit `--no-music` / `--no-sfx`.

## Mix

Levels are starting points for each placed track, as linear gain with 1.0 = file level (dB: 0.3 ≈ -10.5, 0.4 ≈ -8, 0.5 ≈ -6). A track level is relative to its file, so it guarantees no absolute loudness; the measured rendered file decides.

| Layer | Gain |
|---|---|
| music | 0.3–0.4 (ceiling 0.5); `deadpan` 0.12–0.22 |
| SFX | 0.55–0.85 |
| voice | leads; music ducks under it |

- An effect starts with its animation, 0.0–0.1 s early at most.
- Loudness gate on the final file, either renderer, run from the output root and only when audio is planned (a silent video has no audio stream to measure): about -14 LUFS integrated and true peak below -1 dBTP, measured with `ffmpeg -i video.mp4 -af ebur128=peak=true -f null -` (confirm options with `ffmpeg -h filter=ebur128`). fframes' `audio analyze` adds per-scene numbers. Levels outside the target go back to the track gains, then re-render.

## Beat sync

Readability and clarity come first; a scene keeps its reading time when it conflicts with a beat.

A beat-sync claim (in the plan, summary or share copy) needs measured beats: in Hyperframes, `npx hyperframes beats <dir> --json` on a composition whose music is `<audio data-timeline-role="music">` writes `beats/<audio-relative-path>.json` (confirm with `beats --help`). An fframes-only video measures with a tool the user approves; without measurements the plan says "timed to the storyboard" and claims nothing about beats. Lock 1–3 major moments (hook, reveal, punchline) to measured beats within ±0.15 s; minor locks within ±0.10 s.

## Voice

`--voice` is opt-in: narration exists only when requested. Steps, each ending on its gate:

1. **Script** into `video-plan.md`: words drawn from the source facts, sized to the planned duration. **Gate:** every sentence traces to a source fact or is marked as authored.
2. **Audio before timing:** a user-supplied recording, or generated speech saved as `work/audio/narration.wav`. **Gate:** the file exists and `ffprobe` reports its duration.
3. **Time the scenes** to that duration (cuts follow sentences). Hyperframes: root `data-duration` = narration length + about 0.5 s.
4. **Mix** in the composition, separate from generation: Hyperframes tracks per the `hyperframes-audio` guide, fframes `AudioTrack::...voice()` with music `duck_under_voice()`.

Generated speech via Kokoro (local, no API key) can serve either renderer:

```bash
npx hyperframes tts "<text or script file>" --voice af_nova --output work/audio/narration.wav
```

`tts --list` shows voices, `--lang` selects language, and `tts --help` is authoritative. Run it from the output root. First use downloads about 311 MB into `~/.cache/hyperframes/tts/`; non-English needs `espeak-ng`. For an fframes video the `npx` fetch is an approval item; the video itself needs no Hyperframes project.

No acceptable TTS (declined setup, failed run, wrong language): ask the user for a recording, approval for the setup, or an explicit decision to drop `--voice`, and stop until answered.

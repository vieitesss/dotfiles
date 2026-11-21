# Static audit scan

Run against touched files (or `blog/src/blog` for a full audit of the website). Every hit is a **candidate**: inspect surrounding context before deciding.

```bash
# Pass touched file paths or a front-end directory (defaults to blog/src/blog)
TARGET="${1:-blog/src/blog}"

# Animated or transitioned non-compositor properties
rg -n '@keyframes' -A12 --glob '*.{css,scss,html,svelte,vue,jsx,tsx}' "$TARGET" \
  | rg '(width|height|top|left|right|bottom|margin|padding|filter|backdrop-filter|box-shadow|clip-path|mask|border-radius|background-(position|size)|font-size)\s*:'
rg -n 'transition\s*:\s*(all|[^;]*(width|height|top|left|margin|padding|filter|box-shadow|clip-path))' "$TARGET"
rg -n 'backdrop-filter|filter\s*:\s*blur' "$TARGET"

# JS-driven animation loops and per-frame layout/paint writes
rg -n 'setInterval|setTimeout\([^,]+,\s*1[0-9]\b' "$TARGET"
rg -n 'requestAnimationFrame' -A15 "$TARGET" \
  | rg '(getBoundingClientRect|offset(Width|Height|Top|Left)|client(Width|Height)|scroll(Top|Height)|getComputedStyle)'
rg -n '\.style\.(top|left|width|height|clipPath|filter)\s*=' "$TARGET"
rg -n "setAttribute\(\s*['\"](d|points|viewBox|width|height|x|y|r)['\"]" "$TARGET"

# Layout thrashing candidates inside loops
rg -n '(for\s*\(|forEach|\.map\()' -A8 "$TARGET" \
  | rg '(getBoundingClientRect|offset(Width|Height)|getComputedStyle|scrollHeight)'

# Scroll, touch, wheel, and resize listeners
rg -n "addEventListener\(\s*['\"](scroll|touchstart|touchmove|wheel)['\"]" "$TARGET" | rg -v passive
rg -n "addEventListener\(\s*['\"](resize|scroll)['\"]" "$TARGET"

# Permanent or broad will-change
rg -n 'will-change' "$TARGET"

# Loading, media dimensions, and fonts
rg -n '<script[^>]*src=' "$TARGET" | rg -v '(defer|async|type="module")'
rg -n '<img\b' "$TARGET" | rg -v '(width=|aspect-ratio)'
rg -n '<img\b' "$TARGET" | rg -v 'loading='
rg -n 'fonts\.googleapis\.com|fonts\.gstatic\.com' "$TARGET"
rg -n '@font-face' -A6 "$TARGET" | rg 'font-face|font-display'

# Expensive SVG filters and heavy assets
rg -n 'feTurbulence|feGaussianBlur|feDisplacementMap|feMorphology' "$TARGET"
find "$TARGET" \
  \( -name node_modules -o -name .git -o -name dist -o -name build -o -name _site -o -name .venv \) -prune -o \
  \( -name '*.svg' -size +100k -o \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) -size +300k -o -name '*.js' -size +150k \) -print
```

## Manual read checks

Inspect touched code for issues grep cannot catch:

- Event handlers doing heavy work before painting visual feedback.
- Node-by-node live DOM construction inside loops.
- Listeners, observers, timers, or animations created without teardown.
- Dynamic content inserted above the fold after load.
- Inline SVGs with excessive node counts (`rg -o '<(path|circle|rect|line|polygon)\b' file.svg | wc -l`).

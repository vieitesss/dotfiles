# Performance rules by domain

Consult the sections relevant to the code you are writing or auditing.

## Animation and rendering

- Animate `transform` (`translate`, `scale`, `rotate`) and `opacity` only. Replace animations of layout or paint properties (`top`, `left`, `width`, `height`, `margin`, `padding`, `font-size`, `filter: blur()`, `backdrop-filter`, `box-shadow`, `text-shadow`, changing `clip-path`/`mask`, SVG geometry `d`/`points`/`r`/`x`/`y`/`width`/`height`/`stroke-dashoffset`/`viewBox`, `background-position`/`size`, `border-radius`, large-area `color`/`background-color`).
- **Draw once, move cheap:**
  - Shadow: render it once on a pseudo-element and animate that layer's `opacity`.
  - Modal backdrop blur: replace `backdrop-filter` with a semi-transparent opacity fade.
  - Shape reveal: slide a fixed-shape mask/window with `transform` instead of recomputing `clip-path` per frame.
  - Zoom: render at the final size, start at `transform: scale(small)`, and animate to `scale(1)` so text stays sharp.
- Drive animations with CSS or WAAPI (`el.animate()`, cancel/rewind via `animation.reverse()` or `playbackRate = -1`). When JS must drive frames, use `requestAnimationFrame` with zero layout reads and `transform`/`opacity` writes only.
- Apply `will-change: transform` only immediately before animation and remove it afterward. Keep promoted layers as small as the effect allows, and animate one container rather than hundreds of children.
- Respect `prefers-reduced-motion` by shortening motion or replacing it with a fade.
- Isolate self-contained widgets with `contain: layout paint` (or `contain: strict` with known size), and long off-screen sections with `content-visibility: auto` plus `contain-intrinsic-size`.

## Layout thrashing

- Batch all geometry reads before style writes; keep reads and writes in separate passes outside loops.
- Layout-forcing reads: `offsetWidth/Height/Top/Left`, `clientWidth/Height`, `scrollWidth/Height/Top/Left`, `getBoundingClientRect()`, `getClientRects()`, `getComputedStyle()`, `innerText`, `el.focus()`, `scrollIntoView()`, `window.scrollY`, `innerWidth/Height`.
- Measure once, cache, and invalidate with `ResizeObserver`. Use `IntersectionObserver` for viewport visibility instead of `scroll` + `getBoundingClientRect()`.
- Mark `scroll`, `touchstart`, `touchmove`, and `wheel` listeners `{ passive: true }` unless they call `preventDefault()`.
- Throttle `resize`/`scroll` handlers to once per frame via `requestAnimationFrame`.

## Main thread and responsiveness (INP)

- Update visible UI state (pressed state, spinner) first, then yield before heavy work.
- Break tasks over 50 ms with a Safari-safe yield helper (`scheduler.yield()` is not in all Safari versions):
  ```js
  const yieldToMain = () =>
    globalThis.scheduler?.yield ? scheduler.yield() : new Promise(r => setTimeout(r, 0));
  ```
- Offload heavy pure computation (parsing, search indexing, image processing) to a Web Worker.
- Use event delegation (one listener on a container) instead of per-item listeners.
- Keep the DOM small and shallow; create hidden UI on demand.
- Schedule non-urgent work (analytics, prefetch) with `requestIdleCallback` plus a fallback.
- Use `textContent` for plain text; assemble multi-node DOM insertions in a `DocumentFragment` or single assignment.

## Loading (LCP)

- Load `<head>` scripts with `defer` or `type="module"`; keep only critical CSS render-blocking.
- Prioritize the LCP element (hero image, first heading/diagram) with `fetchpriority="high"`, add `<link rel="preload">` if late-discovered (for example, a CSS background), and omit `loading="lazy"`.
- Add `loading="lazy"` and `decoding="async"` to below-the-fold images and iframes.
- Serve responsive images (`srcset` + `sizes`, AVIF/WebP with fallback) sized near display width.
- Serve content-hashed static assets with `Cache-Control: max-age=31536000, immutable` and short/`no-cache` headers on HTML.
- Limit `<link rel="preconnect">` to at most 2–3 origins needed immediately.

## Layout stability (CLS)

- Set `width` and `height` attributes or CSS `aspect-ratio` on every `<img>`, `<video>`, `<iframe>`, and external `<svg>`.
- Reserve space for late-injected UI (embeds, banners, copy buttons, TOC), and insert dynamic content below the active viewport.
- Move elements with `transform` rather than `top`/`height`.

## Fonts

- Self-host WOFF2 fonts instead of cross-origin font stylesheets.
- Subset to needed scripts and weights, preferring one variable font over multiple static files.
- Use `font-display: swap` (or `optional` for non-essential fonts) with fallback metrics (`size-adjust`, `ascent-override`, `descent-override`) to prevent swap shift.
- Preload only the 1–2 fonts used above the fold: `<link rel="preload" as="font" type="font/woff2" crossorigin>`.

## SVG

- Optimize SVGs with SVGO (strip metadata, merge paths, round coordinates) and watch inline node counts.
- Replace live SVG filters (`feTurbulence`, `feGaussianBlur`, `feDisplacementMap`, `feMorphology`) on large or repainted areas with pre-rendered small raster tiles (PNG/WebP).
- Animate a wrapper's CSS `transform`/`opacity` instead of SVG attributes.
- Choose inline SVG only when CSS-variable theming is needed; otherwise use `<img>` for caching and lower DOM cost.
- Keep `vector-effect: non-scaling-stroke` off animated scaled elements (it forces repaints).

## JavaScript weight and third parties

- Prefer platform primitives (`<dialog>`, WAAPI, `Intl`, Observers, `fetch`, CSS smooth scroll) before adding a library; check minified + gzipped size for every new dependency.
- Dynamically import code that is only needed on interaction; keep static/content pages readable before JS executes.
- Use click-to-load facades for heavy embeds (video, maps, comments) and defer or idle-load lightweight analytics.

## Memory and cleanup

- Clean up every `addEventListener`, observer, `setInterval`, and animation when its view unmounts; wire listeners to an `AbortController` `{ signal }`.
- Commit final animation state with `animation.commitStyles()` and call `animation.cancel()` instead of accumulating `fill: "forwards"` animations.
- Release references to removed DOM nodes held in closures or arrays.

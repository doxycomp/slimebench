# web — the browser page

The interactive frontend: the TypeScript simulation on an HTML5 canvas, with
sliders for every SPEC-1 parameter.

`index.html` is markup only. The simulation is
[`impl/ts/src/main-web.ts`](../ts/src/main-web.ts), bundled into `app.js` by
`npm run build:web` — which is why `app.js` is not in git. The per-parameter
sliders are not in the page either: `main-web.ts` builds them into `#controls`
from the parameter list, so the page cannot fall out of step with the
simulation it drives.

The moment a parameter is moved, the overlay marks the run **EDITED**. It has
left the SPEC-1 configuration and its checksums no longer reproduce anything —
which is the whole reason the marker exists, because a screenshot of a
hand-tuned run is otherwise indistinguishable from a conformant one.

## Targets

<!-- sb:impl targets -->
_No benchmark target builds from this directory._
<!-- /sb:impl -->

## Files

<!-- sb:impl files -->
| File | Lines | What |
|---|---:|---|
| `index.html` | 187 | The browser frontend: page, canvas and controls |
<!-- /sb:impl -->

## Building

```bash
cd impl/ts && npm install && npm run build:web
python3 -m http.server 8765 --directory ../web
```

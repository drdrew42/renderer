# Backlog

Ideas deferred from thin-first API design. Promote to issues / tickets when there's a real consumer asking.

## Thick-API candidates

- **Combined `sendCss({elements, templates})` convenience** — the renderer requires the parent to split combined payloads into two namespaced messages (`webwork.command.css.elements` + `webwork.command.css.templates`). The thin API expresses this at the type level — `cssElements` and `cssTemplates` take single fields, can't be combined. A thick helper could take a combined object and emit two `send()` calls under the hood. Reintroduces the legacy payload ergonomics without the wire-shape baggage.

- **`RendererClient` class** wrapping an iframe — exposes `onLoaded(cb)`, `onSubmitted(cb)`, `sendCss(...)`, hides frame routing entirely. Worth designing only after two integrators have written near-identical dispatch boilerplate on top of the thin API. Premature otherwise.

- **`bindResize(iframe, frame?)` listener auto-registration** — wires up the `message` listener + `applyResize` + frame filter in one call. Trivial to write once we know what consumers actually want it to do (filter by frame? handle multiple iframes? respect a max height?).

- **`applyResize(iframe, msg, {minHeight})` option** — WW3 portal floors resize at 600px via inline `Math.max(height, MIN_HEIGHT)`. If a second consumer wants the same floor, promote to an options arg on `applyResize`. Single-consumer: not worth adding.

- ~~**Parameterized `Verdict<S>`**~~ — **Done** (v0). Promoted to actual types after the WW3-portal touchstone confirmed the renderer is a dumb pipe at the verdict boundary, and the integrator owns the inner-status shape via its answerURL response contract. `Verdict<S>`, `InteractionSubmitted<S>`, `FromRenderer<S>`, and `parseFromRenderer<S>` all parameterize through. Default `S = unknown`.

## Protocol-level follow-ups

- **Verdict `message` double-encoding** — `lib/Renderer/Render/AnswerURL.pm::post_p` sometimes emits `message` as a JSON-stringified blob. Renderer-side fix would let `Verdict.message` widen to `string | object | unknown` (or stay `string` but be guaranteed-non-JSON-blob). Tracked in `WeBWorK/Renderer/postMessage Protocol.md` § Open questions.

## Tooling

- **Test harness** — Vitest + happy-dom or jsdom, exercise `parseFromRenderer` against the four inbound categories. Skipped at v0; the package is small enough to read end-to-end, but a smoke test pre-publish would catch type-discriminant typos.

- **CI workflow** — `npm ci && npm run typecheck && npm run build` on PRs. Trivial once the package has its first consumer.

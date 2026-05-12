# @openwebwork/renderer-client

Typed postMessage client for the WeBWorK standalone renderer. Zero runtime dependencies.

Authoritative spec: [`WeBWorK/Renderer/postMessage Protocol.md`](../../WeBWorK/Renderer/postMessage%20Protocol.md). This README is the integrator's quick-start; the spec is the source of truth.

---

## Install

```bash
npm install @openwebwork/renderer-client
```

## What this package does

- Provides discriminated-union TypeScript types for every `webwork.<class>.<verb>` message in the protocol — both directions (`FromRenderer`, `ToRenderer`).
- Exposes `parseFromRenderer(event)` to unwrap a raw `MessageEvent` into a narrowed, typed message — with light-touch runtime validation of `type` and `frame`.
- Exposes constructor functions (`cssElements`, `cssTemplates`, `submit`, `querySolutions`, `queryHints`) that build well-formed outbound messages.
- Exposes `send(target, message, origin)` to stringify and post.
- Exposes `applyResize(iframe, msg)` as the default replacement for iframe-resizer's host-side height application.

It deliberately does **not** wrap the iframe in a class, auto-register listeners, or manage frame routing for you. See [`BACKLOG.md`](./BACKLOG.md) for the thicker abstractions deferred until real demand emerges.

---

## Quick start

```ts
import {
  parseFromRenderer,
  send,
  cssElements,
  applyResize,
  FROM_RENDERER,
} from "@openwebwork/renderer-client";

const iframe = document.querySelector("iframe#webwork") as HTMLIFrameElement;
const iframeOrigin = "https://wwrenderer.libretexts.org";

window.addEventListener("message", (event) => {
  const msg = parseFromRenderer(event);
  if (!msg) return; // not ours — silently ignored

  switch (msg.type) {
    case FROM_RENDERER.LIFECYCLE_LOADED:
      // reply with the CSS we want applied
      if (event.source) {
        send(
          event.source,
          cssElements({
            frame: msg.frame,
            elements: [{ selector: "div#problem_body", style: "background: none;" }],
          }),
          event.origin,
        );
      }
      break;

    case FROM_RENDERER.LIFECYCLE_RESIZE:
      applyResize(iframe, msg);
      break;

    case FROM_RENDERER.INTERACTION_SUBMITTED: {
      const verdict = msg.status;
      const ok = verdict.status < 300;
      // verdict.message may itself be JSON-stringified — see "Verdict shape" below
      handleSubmission(ok, verdict);
      break;
    }

    case FROM_RENDERER.INTERACTION_ATTEMPT:
      // client-side score read (problem-result-score element); msg.status is a string
      break;
  }
});
```

`parseFromRenderer` returns `null` for:

- `[iFrameSizer]…` chatter (when the renderer ships iframe-resizer under `LEGACY_IFRAME_RESIZER=1`) — the iframe-resizer host script's own listener handles these independently.
- Non-JSON strings or JSON without `type: 'webwork.*'` — host-page senders we don't speak for.
- `webwork.*` messages missing `frame` or with an unknown `type` — these log a `console.warn` first.

---

## Sending commands

For replies, target `event.source` and use `event.origin`:

```ts
if (event.source) {
  send(event.source, cssTemplates({ frame: msg.frame, templates: [
    ".btn-primary:hover { color: white !important; }",
  ]}), event.origin);
}
```

For push-initiated commands (e.g. applying CSS without an inbound trigger), target `iframe.contentWindow` with the iframe's origin:

```ts
if (iframe.contentWindow) {
  send(iframe.contentWindow, submit({ frame: "p1" }), iframeOrigin);
}
```

Avoid `targetOrigin: '*'` once you know the iframe's origin. A misconfigured or hijacked iframe shouldn't silently receive messages meant for the renderer.

---

## Frame routing

Every `webwork.*` message carries `frame: string`. The renderer derives it at boot from `window.name` (set by the embedder via `<iframe name="...">`), falling back to `frameElement?.id` or `frameElement?.dataset.id`, then `'no-id'`.

**Gotcha**: if the renderer is built with `LEGACY_IFRAME_RESIZER=1`, the iframe-resizer client script overwrites `window.name` with `iFrameResizer<N>` (auto-incrementing) **before** `problem.js` reads it. Anything you put in `<iframe name="...">` is lost. For single-iframe-per-page integrations this is harmless; for multi-iframe composition either drop iframe-resizer or live with auto-named frames.

The going-forward path: migrate off iframe-resizer onto `webwork.lifecycle.resize` + `applyResize`, set `LEGACY_IFRAME_RESIZER=0` on the renderer, and `<iframe name="...">` is yours again.

---

## Verdict shape — what's the renderer's vs. what's yours

`webwork.interaction.submitted` wraps the orchestrator's answerURL response under `status`:

```ts
{
  type: "webwork.interaction.submitted",
  frame: "p1",
  status: {
    subject: "...",                  // renderer-set routing tag
    message: "...",                  // renderer default, often overridden by orchestrator
    status:  <orchestrator-defined>, // ← your contract with your orchestrator
    // ...any JSON fields the orchestrator's body returned are shallow-merged on top
  }
}
```

The boundary is sharp:

- **The renderer guarantees** the envelope (`type`, `frame`), the routing-tag `subject`, the default `message`, and the *presence* of `status`. The renderer is a dumb pipe — it forwards your orchestrator's answerURL response back to you, with the HTTP code as the overlay default.
- **Your answerURL response contract** — between you and your orchestrator — defines the shape of the inner `status` field and any app-specific fields. This is not the renderer's domain.

Concretely, the inner `status` field's type depends on what your orchestrator returns:

| Orchestrator | Returns | Inner `status` consumers see |
|---|---|---|
| WW3 | `{status: 'accepted' \| 'rejected' \| 'stale'}` | string enum |
| ADAPT | (no `status` in body) | HTTP code (number) |
| Yours? | Whatever you define | Whatever you define |

## Bring your own status type

The package types parameterize `Verdict<S>`, `InteractionSubmitted<S>`, and `FromRenderer<S>` over your status shape. Declare it once at the call site:

```ts
type MyStatus = 'accepted' | 'rejected' | 'stale';

window.addEventListener("message", (event) => {
  const msg = parseFromRenderer<MyStatus>(event);
  if (!msg) return;

  if (msg.type === FROM_RENDERER.INTERACTION_SUBMITTED) {
    // msg.status is now Verdict<MyStatus>
    // msg.status.status is typed MyStatus, no cast needed
    if (msg.status.status === 'accepted') {
      // ...
    }
  }
});
```

Without the type parameter, `Verdict.status` is `unknown` — you'll need to narrow with `typeof` or your own type guard:

```ts
const msg = parseFromRenderer(event); // FromRenderer<unknown> | null
if (msg?.type === FROM_RENDERER.INTERACTION_SUBMITTED) {
  if (typeof msg.status.status === 'string' && msg.status.status === 'accepted') {
    // ...
  }
}
```

**The runtime check in `parseFromRenderer` does not validate the verdict shape** — that's the integrator's assertion, expressed via the type parameter. If you want runtime enforcement (Zod, valibot, hand-rolled type guards), apply it at the dispatch site after narrowing on `type`. The package stays out of that decision deliberately — verdict-shape validation is your boundary with your orchestrator.

`subject` and `message` are typed as `string` — that's the renderer's intent and the conventional contract. A misbehaving orchestrator could technically override them with non-strings via shallow-merge; narrow defensively if you don't trust your orchestrator.

**Double-encoded `message` caveat:** the renderer's `message` field is sometimes itself a JSON-stringified blob (a renderer-side wart, tracked in the protocol doc's § Open questions). Code defensively:

```ts
let body: unknown = verdict.message;
try { body = JSON.parse(verdict.message); } catch { /* not JSON, use as-is */ }
```

---

## Origin gating

The renderer declares its parent's origin via a `parent_origin` JWT claim → `<html data-parent-origin="...">`. Parents are expected to do the symmetric thing: only act on messages from the iframe's known origin. The package doesn't enforce this for you — `parseFromRenderer` accepts any origin — but the spec recommends:

```ts
window.addEventListener("message", (event) => {
  if (event.origin !== iframeOrigin) return;
  const msg = parseFromRenderer(event);
  // ...
});
```

---

## Versioning

Semver tied to protocol revisions:

- **Major** — incompatible shape change to an existing message type, or a removed type.
- **Minor** — new message type added.
- **Patch** — implementation-only changes (parser bug fixes, JSDoc updates, etc.).

Each release's CHANGELOG entry references the renderer-side ticket(s) it tracks.

---

## What's not (yet) in this package

See [`BACKLOG.md`](./BACKLOG.md). Notable items: combined-CSS convenience constructor, `RendererClient` class wrapper, listener auto-registration.

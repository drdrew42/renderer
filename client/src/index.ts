// @openwebwork/renderer-client
//
// Typed postMessage client for the WeBWorK standalone renderer.
// Spec: WeBWorK/Renderer/postMessage Protocol.md
//
// Direction is consumer-POV (a parent embedding a renderer iframe):
//   FromRenderer  — messages the parent receives from the iframe
//   ToRenderer    — messages the parent sends to the iframe

// ── Shared shapes ────────────────────────────────────────────────────────────

/**
 * Parsed verdict object — the `status` payload of `webwork.interaction.submitted`.
 *
 * Assembled by `lib/Renderer/Render/AnswerURL.pm::post_p`, JSON-encoded into the
 * `JWTanswerURLstatus` form field, parsed in `problem.js`, and placed under
 * `status` in the envelope.
 *
 * **Boundary: what's the renderer's contract vs. the answerURL's.**
 *
 * The renderer is a dumb pipe — it forwards the orchestrator's answerURL
 * response back to the parent, with the HTTP status as an overlay default.
 * The shape of `status` (and the orchestrator-specific fields under the index
 * signature) belongs to the **answerURL response contract**, which is between
 * the integrator and their orchestrator — not the renderer protocol.
 *
 * **Renderer-guaranteed fields:**
 *
 * - `subject`: renderer-set routing tag (string constant). Orchestrators can
 *   technically override via shallow-merge but conventionally don't.
 * - `message`: renderer-set default, often overridden by the orchestrator's
 *   response body. Sometimes itself a JSON-stringified blob (renderer-side
 *   wart; tracked in the protocol doc's § Open questions). Code defensively
 *   by attempting JSON.parse(message) inside a try/catch.
 *
 * **Integrator-owned field (`S` type parameter):**
 *
 * - `status`: typed as `S` (default `unknown`). Two producers write to it in
 *   order: the renderer sets it to the HTTP status of the answerURL POST,
 *   then shallow-merges the response body on top. The body's `status` (if
 *   present) wins. Concretely:
 *     - Orchestrator returns `{status: 'accepted'}` → `'accepted'`
 *     - Orchestrator returns no `status` → HTTP code (number)
 *
 * Bring your own status shape by parameterizing the generic:
 *
 * ```ts
 * type WW3Status = 'accepted' | 'rejected' | 'stale';
 * const msg = parseFromRenderer<WW3Status>(event);
 * // msg.status, when type === INTERACTION_SUBMITTED, is Verdict<WW3Status>
 * // — its inner `status` field is typed WW3Status, not unknown.
 * ```
 *
 * The runtime check in `parseFromRenderer` does **not** validate the verdict
 * shape; that's the integrator's assertion via the type parameter. Bring your
 * own validator (Zod, valibot, type guards) at the dispatch site if you want
 * runtime enforcement.
 *
 * Additional fields from the orchestrator's response body are shallow-merged
 * on top — covered by the open index signature.
 */
export interface Verdict<S = unknown> {
	subject: string;
	message: string;
	status: S;
	[key: string]: unknown;
}

/**
 * Per-element style/class update for `webwork.command.css.elements`.
 * The renderer applies via `el.style.cssText` and/or `el.className`.
 *
 * Plain `style` values are overridden by `hideElements` JWT-claim stylesheet
 * `!important`; use `!important` in the style string to win the cascade.
 */
export interface ElementUpdate {
	selector: string;
	style?: string;
	class?: string;
}

// ── Message type constants ───────────────────────────────────────────────────

export const FROM_RENDERER = {
	LIFECYCLE_LOADED: "webwork.lifecycle.loaded",
	LIFECYCLE_RESIZE: "webwork.lifecycle.resize",
	SESSION_MINTED: "webwork.session.minted",
	INTERACTION_ATTEMPT: "webwork.interaction.attempt",
	INTERACTION_SUBMITTED: "webwork.interaction.submitted",
	INTERACTION_FOCUS: "webwork.interaction.focus",
	INTERACTION_BLUR: "webwork.interaction.blur",
	INTERACTION_TOOLBAR: "webwork.interaction.toolbar",
	INTERACTION_HINT: "webwork.interaction.hint",
	INTERACTION_SOLUTION: "webwork.interaction.solution",
	INTERACTION_FIELD: "webwork.interaction.field",
	CSS_UPDATE: "webwork.css.update",
	CONTENT_SOLUTIONS: "webwork.content.solutions",
	CONTENT_HINTS: "webwork.content.hints",
} as const;

export const TO_RENDERER = {
	CSS_ELEMENTS: "webwork.command.css.elements",
	CSS_TEMPLATES: "webwork.command.css.templates",
	SUBMIT: "webwork.command.submit",
	QUERY_SOLUTIONS: "webwork.query.solutions",
	QUERY_HINTS: "webwork.query.hints",
} as const;

// ── FromRenderer (iframe → parent) ───────────────────────────────────────────

interface FromRendererBase {
	frame: string;
}

export interface LifecycleLoaded extends FromRendererBase {
	type: typeof FROM_RENDERER.LIFECYCLE_LOADED;
}

export interface LifecycleResize extends FromRendererBase {
	type: typeof FROM_RENDERER.LIFECYCLE_RESIZE;
	height: number;
}

export interface SessionMinted extends FromRendererBase {
	type: typeof FROM_RENDERER.SESSION_MINTED;
	session_jwt: string;
	/**
	 * Whether the rendered problem has a PG `SOLUTION` block (WW3-142). Lets a
	 * consumer gate a "view solution" affordance before rendering it. Present on
	 * the play render; optional so pre-field messages still parse.
	 */
	has_solution?: boolean;
}

/** Client-side score read from `problem-result-score` DOM element. */
export interface InteractionAttempt extends FromRendererBase {
	type: typeof FROM_RENDERER.INTERACTION_ATTEMPT;
	status: string;
}

/**
 * Server-side verdict from the answerURL POST. See {@link Verdict}.
 *
 * The generic `S` is the integrator's inner-status shape — declare it via the
 * type parameter on {@link parseFromRenderer} (or on {@link FromRenderer}).
 */
export interface InteractionSubmitted<S = unknown> extends FromRendererBase {
	type: typeof FROM_RENDERER.INTERACTION_SUBMITTED;
	status: Verdict<S>;
}

export interface InteractionFocus extends FromRendererBase {
	type: typeof FROM_RENDERER.INTERACTION_FOCUS;
	id: string;
}

export interface InteractionBlur extends FromRendererBase {
	type: typeof FROM_RENDERER.INTERACTION_BLUR;
	id: string;
}

/** Synthesized from a focus/blur sequence around a MathQuill toolbar click. */
export interface InteractionToolbar extends FromRendererBase {
	type: typeof FROM_RENDERER.INTERACTION_TOOLBAR;
	id: string;
}

export interface InteractionHint extends FromRendererBase {
	type: typeof FROM_RENDERER.INTERACTION_HINT;
	id: string;
	status: string;
}

export interface InteractionSolution extends FromRendererBase {
	type: typeof FROM_RENDERER.INTERACTION_SOLUTION;
	id: string;
	status: string;
}

/**
 * Per-field debounced edit (WW3-R32). Emitted ~200ms after each user edit by
 * `draft-tracker.js`. Pair-aware (AnSwEr* + MaThQuIlL_AnSwEr*) and idempotent.
 */
export interface InteractionField extends FromRendererBase {
	type: typeof FROM_RENDERER.INTERACTION_FIELD;
	id: string;
	value: string;
}

/** Reply to a `webwork.command.css.*` message. */
export interface CssUpdate extends FromRendererBase {
	type: typeof FROM_RENDERER.CSS_UPDATE;
	update: string;
}

/** Reply to a `webwork.query.solutions` message. */
export interface ContentSolutions extends FromRendererBase {
	type: typeof FROM_RENDERER.CONTENT_SOLUTIONS;
	solutions: string[];
}

/** Reply to a `webwork.query.hints` message. */
export interface ContentHints extends FromRendererBase {
	type: typeof FROM_RENDERER.CONTENT_HINTS;
	hints: string[];
}

/**
 * Discriminated union of every message the renderer emits.
 *
 * The generic `S` parameterizes only the {@link InteractionSubmitted} variant's
 * verdict inner-status type. Default `unknown`; bring your own via the type
 * parameter on {@link parseFromRenderer}:
 *
 * ```ts
 * type MyStatus = 'accepted' | 'rejected';
 * const msg = parseFromRenderer<MyStatus>(event);
 * // msg: FromRenderer<MyStatus> | null
 * ```
 *
 * Other variants don't carry integrator-defined payloads — their fields are
 * renderer-guaranteed and unaffected by `S`.
 */
export type FromRenderer<S = unknown> =
	| LifecycleLoaded
	| LifecycleResize
	| SessionMinted
	| InteractionAttempt
	| InteractionSubmitted<S>
	| InteractionFocus
	| InteractionBlur
	| InteractionToolbar
	| InteractionHint
	| InteractionSolution
	| InteractionField
	| CssUpdate
	| ContentSolutions
	| ContentHints;

// ── ToRenderer (parent → iframe) ─────────────────────────────────────────────

interface ToRendererBase {
	frame: string;
}

/**
 * Apply per-element style/class updates. The renderer replies with `CssUpdate`.
 *
 * Legacy combined `{elements, templates}` payloads must split into two
 * messages: {@link CssElementsCommand} + {@link CssTemplatesCommand}.
 */
export interface CssElementsCommand extends ToRendererBase {
	type: typeof TO_RENDERER.CSS_ELEMENTS;
	elements: ElementUpdate[];
}

/**
 * Append CSS strings as `<style>` blocks in `<head>`. Replies with `CssUpdate`.
 */
export interface CssTemplatesCommand extends ToRendererBase {
	type: typeof TO_RENDERER.CSS_TEMPLATES;
	templates: string[];
}

/** Trigger the iframe's form submission. Used for batch-submit choreography. */
export interface SubmitCommand extends ToRendererBase {
	type: typeof TO_RENDERER.SUBMIT;
}

/** Read solution bodies from the iframe. Replies with `ContentSolutions`. */
export interface QuerySolutions extends ToRendererBase {
	type: typeof TO_RENDERER.QUERY_SOLUTIONS;
}

/** Read hint bodies from the iframe. Replies with `ContentHints`. */
export interface QueryHints extends ToRendererBase {
	type: typeof TO_RENDERER.QUERY_HINTS;
}

export type ToRenderer =
	| CssElementsCommand
	| CssTemplatesCommand
	| SubmitCommand
	| QuerySolutions
	| QueryHints;

// ── Parsing ──────────────────────────────────────────────────────────────────

const FROM_RENDERER_TYPES: ReadonlySet<string> = new Set(Object.values(FROM_RENDERER));

/**
 * Unwrap a `MessageEvent` into a typed `FromRenderer` message, or `null` if
 * the event isn't one of ours.
 *
 * Behavior by inbound category:
 *
 * - **iframe-resizer chatter** (`[iFrameSizer]…` strings, emitted when the
 *   renderer is built with `LEGACY_IFRAME_RESIZER=1`): silent `null`. The
 *   iframe-resizer host script registers its own listener and handles these
 *   independently — they're not yours to interpret.
 * - **Non-JSON strings, or JSON without `type: 'webwork.*'`**: silent `null`.
 *   The host page may have other senders; we don't speak for them.
 * - **`webwork.*` shape missing `frame`**: `console.warn` + `null`. Symmetric
 *   with the renderer-side warn-and-drop in `css-message.js`.
 * - **`webwork.*` shape with unknown `type`**: `console.warn` + `null`. The
 *   renderer is newer than this client; update the package.
 *
 * Runtime guards are deliberately light-touch: `type` and `frame` only. Payload
 * shape past those two fields is trusted to match the declared variant — the
 * TS narrowing reflects a wire contract, not a defensive validator.
 *
 * @example
 * window.addEventListener('message', (event) => {
 *   const msg = parseFromRenderer(event);
 *   if (!msg) return;
 *   switch (msg.type) {
 *     case FROM_RENDERER.LIFECYCLE_LOADED: ... break;
 *     case FROM_RENDERER.INTERACTION_SUBMITTED: ... break;
 *   }
 * });
 */
export function parseFromRenderer<S = unknown>(event: MessageEvent): FromRenderer<S> | null {
	const raw = event.data;

	let candidate: unknown;
	if (typeof raw === "string") {
		if (raw.startsWith("[iFrameSizer]")) return null;
		try {
			candidate = JSON.parse(raw);
		} catch {
			return null;
		}
	} else if (raw && typeof raw === "object") {
		candidate = raw;
	} else {
		return null;
	}

	if (!candidate || typeof candidate !== "object") return null;
	const record = candidate as Record<string, unknown>;

	const type = record["type"];
	if (typeof type !== "string" || !type.startsWith("webwork.")) return null;

	if (!FROM_RENDERER_TYPES.has(type)) {
		console.warn(
			`[@openwebwork/renderer-client] unknown message type: ${type}. ` +
				`This client may be older than the renderer emitting it. ` +
				`See WeBWorK/Renderer/postMessage Protocol.md`,
		);
		return null;
	}

	const frame = record["frame"];
	if (typeof frame !== "string") {
		console.warn(
			`[@openwebwork/renderer-client] dropped ${type}: missing or non-string "frame" field. ` +
				`The frame field is required on webwork.* messages. ` +
				`See WeBWorK/Renderer/postMessage Protocol.md`,
		);
		return null;
	}

	return record as unknown as FromRenderer<S>;
}

// ── Constructors ─────────────────────────────────────────────────────────────

/**
 * Build a `webwork.command.css.elements` message. Apply per-element style/class
 * updates to the iframe. Renderer replies with {@link CssUpdate}.
 *
 * Legacy combined `{elements, templates}` payloads must split — pair this with
 * {@link cssTemplates} and send both messages.
 */
export function cssElements(args: { frame: string; elements: ElementUpdate[] }): CssElementsCommand {
	return { type: TO_RENDERER.CSS_ELEMENTS, frame: args.frame, elements: args.elements };
}

/**
 * Build a `webwork.command.css.templates` message. Append each string as a
 * `<style>` block in the iframe's `<head>`. Renderer replies with {@link CssUpdate}.
 */
export function cssTemplates(args: { frame: string; templates: string[] }): CssTemplatesCommand {
	return { type: TO_RENDERER.CSS_TEMPLATES, frame: args.frame, templates: args.templates };
}

/**
 * Build a `webwork.command.submit` message. Triggers the iframe's form
 * submission — used by parents orchestrating batch submit across N iframes.
 */
export function submit(args: { frame: string }): SubmitCommand {
	return { type: TO_RENDERER.SUBMIT, frame: args.frame };
}

/**
 * Build a `webwork.query.solutions` message. Renderer replies with
 * {@link ContentSolutions} carrying solution bodies from the DOM.
 */
export function querySolutions(args: { frame: string }): QuerySolutions {
	return { type: TO_RENDERER.QUERY_SOLUTIONS, frame: args.frame };
}

/**
 * Build a `webwork.query.hints` message. Renderer replies with
 * {@link ContentHints} carrying hint bodies from the DOM.
 */
export function queryHints(args: { frame: string }): QueryHints {
	return { type: TO_RENDERER.QUERY_HINTS, frame: args.frame };
}

// ── Sending ──────────────────────────────────────────────────────────────────

/**
 * Stringify a `ToRenderer` message and post it to a target window.
 *
 * - For push-initiated commands, pass `iframe.contentWindow` as `target` and
 *   the iframe's origin as `targetOrigin`.
 * - For replies to an inbound message, pass `event.source` as `target` and
 *   `event.origin` as `targetOrigin`.
 *
 * Avoid `'*'` once you know the iframe's origin — a misconfigured or hijacked
 * iframe shouldn't silently swallow messages meant for the renderer.
 *
 * @example
 * // Reply to an inbound lifecycle.loaded:
 * const msg = parseFromRenderer(event);
 * if (msg?.type === FROM_RENDERER.LIFECYCLE_LOADED && event.source) {
 *   send(event.source, cssElements({ frame: msg.frame, elements: [...] }), event.origin);
 * }
 */
export function send(
	target: Window | MessageEventSource,
	message: ToRenderer,
	targetOrigin: string,
): void {
	(target as Window).postMessage(JSON.stringify(message), targetOrigin);
}

// ── Defaults ─────────────────────────────────────────────────────────────────

/**
 * Apply a `webwork.lifecycle.resize` message to an iframe element by setting
 * its inline height. Replaces the iframe-resizer host-side handler.
 *
 * Multi-iframe parents are responsible for the `frame` → `HTMLIFrameElement`
 * mapping; this helper applies one message to one iframe.
 *
 * @example
 * window.addEventListener('message', (event) => {
 *   const msg = parseFromRenderer(event);
 *   if (msg?.type === FROM_RENDERER.LIFECYCLE_RESIZE) {
 *     applyResize(myIframe, msg);
 *   }
 * });
 */
export function applyResize(iframe: HTMLIFrameElement, message: LifecycleResize): void {
	iframe.style.height = `${message.height}px`;
}

// Draft tracker: emit per-field updates over postMessage so the parent can
// maintain a draft buffer of in-flight typed-but-not-submitted values.
// See WeBWorK/Renderer/postMessage Protocol.md for the event shape and
// WeBWorK/Tasks/done/WW3-R32 for the design rationale.
//
// Architecture: this script is a renderer-side companion to problem.js and
// css-message.js, registered in third_party_js. mqeditor.js is PG-provided
// (lib/PG/htdocs/js/MathQuill/mqeditor.js) and updates the AnSwEr*/MaThQuIlL_*
// fields via plain assignment (no dispatchEvent — empirical finding,
// mqeditor.js:264-265). So we don't get DOM input events when MathQuill
// updates the underlying fields. Workaround: listen for input + keyup on
// the form (MathQuill keystrokes bubble through the underlying textarea),
// debounce per field-id past mqeditor.js's update cycle, then read the
// current value off the actual answer field. No PG modification, no
// mqeditor.js modification.

(() => {
	const form = document.getElementById('problemMainForm');
	if (!form) return;

	// Frame identification matches problem.js — window.name is cross-origin
	// safe; frameElement is null cross-origin. Embedders that need routing
	// (multi-problem composition) set <iframe name="...">.
	const frame =
		window.name ||
		window.frameElement?.id ||
		window.frameElement?.dataset.id ||
		'no-id';

	// postMessage target origin — declared by the trusted render-request
	// source via parent_origin JWT claim → <html data-parent-origin>. Absent
	// → wildcard '*' (legacy behavior; acceptable on unauthenticated preview
	// renders where no listener is expected).
	const parentOrigin = document.documentElement.dataset.parentOrigin || '*';

	// Debounce window: MathQuill's internal edit callback runs *after* the
	// keystroke event we're listening to, so reading the field value
	// immediately gives stale data. 200ms is enough headroom for mqeditor.js
	// to complete the AnSwEr*/MaThQuIlL_* assignments. Doubles as a
	// keystroke-storm coalescer.
	const DEBOUNCE_MS = 200;

	// Per-field debounce timer + last-emitted value memo. Suppresses noisy
	// re-emits when the value didn't actually change (focus-without-edit,
	// keyup of a modifier key, etc.).
	const timers = new Map();
	const lastValue = new Map();

	function emitField(id) {
		const el = document.getElementById(id);
		if (!el) return;
		const value = typeof el.value === 'string' ? el.value : '';
		if (lastValue.get(id) === value) return;
		lastValue.set(id, value);
		window.parent.postMessage(
			JSON.stringify({
				type: 'webwork.interaction.field',
				frame: frame,
				id: id,
				value: value
			}),
			parentOrigin
		);
	}

	function scheduleEmit(id) {
		clearTimeout(timers.get(id));
		timers.set(
			id,
			setTimeout(() => {
				timers.delete(id);
				emitField(id);
				// MathQuill pair-aware emit: when the answer is `AnSwEr*`,
				// also emit the LaTeX-side `MaThQuIlL_AnSwEr*` field if it
				// exists. The parent needs both halves to round-trip cleanly
				// (per Position State.md prefill notes — mqeditor.js's
				// 100ms-delayed mathField.latex() init has nothing to render
				// the visual from without the LaTeX side).
				if (id.startsWith('AnSwEr')) {
					const pairId = `MaThQuIlL_${id}`;
					if (document.getElementById(pairId)) {
						emitField(pairId);
					}
				}
			}, DEBOUNCE_MS)
		);
	}

	function resolveAnswerId(event) {
		// Same composedPath reduce pattern as problem.js's focus/blur logic.
		// Walks the bubble path bottom-up and takes the first element with an
		// id. For plain inputs that's the input itself; for MathQuill
		// activity the path passes through the textarea (no id), various
		// MathQuill internals, then the wrapper element with id
		// `mq-answer-AnSwEr0001`. Strip the `mq-answer-` prefix to recover
		// the underlying answer id either way.
		const raw = event.composedPath().reduce((s, el) => (s ? s : el.id), '');
		if (!raw) return null;
		// problem_body itself is form-level; ignore non-field bubbling.
		if (raw === 'problem_body' || raw === 'problemMainForm') return null;
		return raw.replace(/^mq-answer-/, '');
	}

	function handler(event) {
		const id = resolveAnswerId(event);
		if (!id) return;
		// Only schedule for fields that actually exist as answer inputs
		// (avoid noise from random elements with ids that happen to bubble).
		if (!document.getElementById(id)) return;
		scheduleEmit(id);
	}

	// Listen to both input and keyup for coverage:
	//   - Plain text fields fire `input` on keystroke (and on programmatic
	//     value change in some browsers; harmless under our debounce + memo).
	//   - MathQuill keystrokes go through its hidden textarea and bubble as
	//     keyup events through the form. The corresponding `input` event
	//     also typically bubbles, but we listen to both for resilience to
	//     differences in MathQuill's underlying widget shape.
	form.addEventListener('input', handler, true);
	form.addEventListener('keyup', handler, true);

	// Flush pending debounced emits before the iframe goes away. beforeunload
	// is the standard hook; visibilitychange covers tab-switch which can
	// freeze timers on some browsers.
	function flushAll() {
		for (const [id, timerId] of timers.entries()) {
			clearTimeout(timerId);
			emitField(id);
			if (id.startsWith('AnSwEr')) {
				const pairId = `MaThQuIlL_${id}`;
				if (document.getElementById(pairId)) emitField(pairId);
			}
		}
		timers.clear();
	}
	window.addEventListener('beforeunload', flushAll);
	document.addEventListener('visibilitychange', () => {
		if (document.visibilityState === 'hidden') flushAll();
	});
})();

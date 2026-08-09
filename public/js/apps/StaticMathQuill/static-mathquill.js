'use strict';

/* global MathQuill */

// WW3-121: read-only MathQuill for static (reView) renders.
//
// The renderer swaps PG's editable mqeditor.js for this file when
// outputFormat=static (see WeBWorK::FormatRenderedProblem) — same pipeline,
// reading each MaThQuIlL_ input's stored LaTeX, but rendering StaticMath rather
// than an editable MathField. mathquill.js (the library) stays loaded; only the
// editor init is replaced. This keeps read-only rendering on the renderer's
// side of the wall rather than forking PG's mqeditor.
(() => {
	if (typeof MathQuill === 'undefined') return;
	const MQ = MathQuill.getInterface();

	document.querySelectorAll('[id^=MaThQuIlL_]').forEach((mqInput) => {
		if (mqInput.dataset.mqStaticInitialized) return;
		mqInput.dataset.mqStaticInitialized = 'true';

		const input = document.getElementById(mqInput.id.replace(/^MaThQuIlL_/, ''));
		if (!input) return;

		const span = document.createElement('span');
		span.id = `mq-answer-${input.id}`;
		for (const cls of ['correct', 'incorrect', 'partially-correct']) {
			if (input.classList.contains(cls)) span.classList.add(cls);
		}
		// Hide the raw input; render its stored LaTeX read-only in the span.
		input.style.display = 'none';
		input.after(span);
		const field = MQ.StaticMath(span);
		field.latex(mqInput.value);
	});

	// Non-MathQuill answer inputs go read-only too (readonly is a no-op on
	// radio/checkbox/select, so those are disabled).
	document
		.querySelectorAll('input.codeshard, textarea.codeshard, textarea.latexentryfield')
		.forEach((el) => {
			el.readOnly = true;
		});
	document.querySelectorAll('input[type=radio], input[type=checkbox], select').forEach((el) => {
		el.disabled = true;
	});
})();

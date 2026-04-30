// postMessage inbound handler. See WeBWorK/Renderer/postMessage Protocol.md
// for the full contract; quick reference:
//
//   * Namespaced shapes (type: 'webwork.<class>.<verb>') REQUIRE `frame`.
//     Missing frame → drop with console.warn. The frame requirement is the
//     price of opting into the new vocabulary; legacy shapes are exempt.
//
//   * Legacy shapes (hasOwnProperty dispatch on `elements`/`templates`/
//     `showSolutions`/`showHints`) are accepted with a once-per-page-load
//     deprecation warning. Removal date open-ended pending integrator
//     migration (WW3-R22, 2026-04-30).
//
//   * Origin gate: when `data-parent-origin` is set, accept only matching
//     origins. When unset on a grounded lane (data-trust-lane in
//     {problem,challenge,peer}) AND an inbound arrives, warn once and
//     honor (defense-in-depth notification: the render-request source
//     should have declared parent_origin but didn't).

const parentOrigin = document.documentElement.dataset.parentOrigin;
const trustLane    = document.documentElement.dataset.trustLane || 'ungrounded';
const groundedLane = trustLane === 'problem' || trustLane === 'challenge' || trustLane === 'peer';
const frameId      = window.name || window.frameElement?.id || window.frameElement?.dataset.id || 'no-id';

// One-shot warn flags so the console doesn't fill with duplicates over the
// course of a session.
const warned = {
	originAbsent: false,
	deprecated:   {} // keyed by legacy shape name
};

function warnOnce(key, message) {
	if (key === 'originAbsent') {
		if (warned.originAbsent) return;
		warned.originAbsent = true;
	} else {
		if (warned.deprecated[key]) return;
		warned.deprecated[key] = true;
	}
	console.warn(message);
}

function applyElements(elements) {
	if (!Array.isArray(elements)) return;
	elements.forEach((incoming) => {
		if (!incoming || !incoming.selector) return;
		const matched = window.document.querySelectorAll(incoming.selector);
		if (incoming.style) matched.forEach((el) => { el.style.cssText = incoming.style; });
		if (incoming.class) matched.forEach((el) => { el.className     = incoming.class; });
	});
}

function applyTemplates(templates) {
	if (!Array.isArray(templates)) return;
	templates.forEach((cssString) => {
		const styleEl = document.createElement('style');
		styleEl.innerText = cssString;
		document.head.insertAdjacentElement('beforeend', styleEl);
	});
}

function readSolutions() {
	const els = Array.from(window.document.querySelectorAll('.solution .accordion-body'));
	return els.map((el) => el.innerHTML);
}

function readHints() {
	const els = Array.from(window.document.querySelectorAll('.hint .accordion-body'));
	return els.map((el) => el.innerHTML);
}

function reply(event, type, payload) {
	event.source.postMessage(
		JSON.stringify({ type: type, frame: frameId, ...payload }),
		event.origin
	);
}

window.addEventListener('message', (event) => {
	// Origin gate: explicit allow-list when parent_origin declared.
	if (parentOrigin && event.origin !== parentOrigin) return;

	let message;
	try {
		message = JSON.parse(event.data);
	} catch (e) {
		if (typeof event.data !== 'string' || !event.data.startsWith('[iFrameSizer]')) {
			console.warn('CSSMessage: message not JSON', event.data);
		}
		return;
	}

	// Grounded-lane warning: the render-request source should have declared
	// parent_origin but didn't, leaving the iframe ungated. Honor anyway.
	if (groundedLane && !parentOrigin) {
		warnOnce(
			'originAbsent',
			`[WeBWorK Renderer] inbound postMessage on grounded lane (${trustLane}) but parent_origin was not declared. ` +
			`Honoring the request, but the iframe is operating ungated. ` +
			`The render-request source should declare parent_origin.`
		);
	}

	// Namespaced dispatch (preferred, post-WW3-R22).
	if (typeof message.type === 'string' && message.type.startsWith('webwork.')) {
		if (!message.frame) {
			console.warn(
				`[WeBWorK Renderer] dropped namespaced postMessage without frame: ${message.type}. ` +
				`The frame field is required on webwork.* messages. ` +
				`See WeBWorK/Renderer/postMessage Protocol.md`
			);
			return;
		}

		switch (message.type) {
			case 'webwork.command.css.elements':
				applyElements(message.elements);
				reply(event, 'webwork.css.update', { update: 'elements updated' });
				return;

			case 'webwork.command.css.templates':
				applyTemplates(message.templates);
				reply(event, 'webwork.css.update', { update: 'templates updated' });
				return;

			case 'webwork.command.submit': {
				const form = document.getElementById('problemMainForm');
				if (form) form.requestSubmit ? form.requestSubmit() : form.submit();
				return;
			}

			case 'webwork.query.solutions':
				reply(event, 'webwork.content.solutions', { solutions: readSolutions() });
				return;

			case 'webwork.query.hints':
				reply(event, 'webwork.content.hints', { hints: readHints() });
				return;

			default:
				console.warn(`[WeBWorK Renderer] unknown namespaced postMessage type: ${message.type}`);
				return;
		}
	}

	// Legacy hasOwnProperty dispatch. Each branch warns once-per-page-load
	// then honors. Removal date is set when integrators have migrated.
	if (message.hasOwnProperty('elements')) {
		warnOnce(
			'elements',
			`[WeBWorK Renderer] received deprecated postMessage shape ({elements: [...]}). ` +
			`Migrate to {type: 'webwork.command.css.elements', frame, elements: [...]}. ` +
			`See WeBWorK/Renderer/postMessage Protocol.md`
		);
		applyElements(message.elements);
		reply(event, 'webwork.css.update', { update: 'elements updated' });
	}

	if (message.hasOwnProperty('templates')) {
		warnOnce(
			'templates',
			`[WeBWorK Renderer] received deprecated postMessage shape ({templates: [...]}). ` +
			`Migrate to {type: 'webwork.command.css.templates', frame, templates: [...]}. ` +
			`See WeBWorK/Renderer/postMessage Protocol.md`
		);
		applyTemplates(message.templates);
		reply(event, 'webwork.css.update', { update: 'templates updated' });
	}

	if (message.hasOwnProperty('showSolutions')) {
		warnOnce(
			'showSolutions',
			`[WeBWorK Renderer] received deprecated postMessage shape ({showSolutions: true}). ` +
			`Migrate to {type: 'webwork.query.solutions', frame}. It is a read, not a 'show'. ` +
			`See WeBWorK/Renderer/postMessage Protocol.md`
		);
		reply(event, 'webwork.content.solutions', { solutions: readSolutions() });
	}

	if (message.hasOwnProperty('showHints')) {
		warnOnce(
			'showHints',
			`[WeBWorK Renderer] received deprecated postMessage shape ({showHints: true}). ` +
			`Migrate to {type: 'webwork.query.hints', frame}. It is a read, not a 'show'. ` +
			`See WeBWorK/Renderer/postMessage Protocol.md`
		);
		reply(event, 'webwork.content.hints', { hints: readHints() });
	}
});

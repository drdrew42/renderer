(() => {
	// Frame identification: window.name works cross-origin (set by the embedder
	// via <iframe name="...">), window.frameElement is null cross-origin. Prefer
	// window.name, fall back to frameElement for same-origin legacy embedders,
	// then 'no-id' when neither is set.
	const frame = window.name || window.frameElement?.id || window.frameElement?.dataset.id || 'no-id';

	// postMessage target origin: declared by the trusted render-request source
	// (JWT claim or peer-signed body field), templated into <html data-parent-origin>.
	// Absent → wildcard '*' (legacy behavior; acceptable when no listener is
	// expected or when the render path is unauthenticated preview).
	const parentOrigin = document.documentElement.dataset.parentOrigin || '*';

	// Lifecycle: announce that the iframe finished loading. Replaces the
	// legacy bare-string `'loaded'` body-onLoad broadcast (WW3-R22). Carries
	// `frame` so multi-iframe parents can route.
	window.parent.postMessage(
		JSON.stringify({
			type: 'webwork.lifecycle.loaded',
			frame: frame
		}),
		parentOrigin
	);

	// Activate the popovers in the results table.
	document.querySelectorAll('.attemptResults .answer-preview[data-bs-toggle="popover"]').forEach((preview) => {
		if (preview.dataset.bsContent) new bootstrap.Popover(preview);
	});

	// Post the most recent renderer-minted sessionJWT to the parent. This is
	// the WW3-053 close-the-loop channel: every iframe load surfaces the
	// current sessionJWT (post-render-time-fold for RESUME, post-answer-URL-
	// fold for submit) so the portal can persist it to localStorage and use
	// it on the next interaction. Decoding the sessionJWT gives the portal
	// the verdict-folded state without needing a separate verdict callback.
	const sessionJWTValue = document.getElementById('sessionJWT')?.value;
	if (sessionJWTValue) {
		// has_solution (WW3-142): whether this problem parsed a PG SOLUTION block.
		// Read off the solutionExists hidden field (1/0) the simple format emits;
		// the portal gates its forfeit-reveal Solution affordance on this.
		const hasSolution = document.getElementById('solutionExists')?.value === '1';
		window.parent.postMessage(
			JSON.stringify({
				type: 'webwork.session.minted',
				session_jwt: sessionJWTValue,
				has_solution: hasSolution,
				frame: frame
			}),
			parentOrigin
		);
	}

	// If there is a JWTanswerURLstatus element, report it to parent. The element
	// value is JSON (post-WW3-R16, encodeAnswerStatus emits plain encode_json).
	// Wrap in the structured envelope (WW3-R22). Replaces the legacy raw-string
	// passthrough; consumers must JSON.parse the .status field.
	const statusValue = document.getElementById('JWTanswerURLstatus')?.value;
	if (statusValue) {
		let parsed;
		try {
			parsed = JSON.parse(statusValue);
		} catch (e) {
			parsed = statusValue; // last-ditch fallback; legacy non-JSON shouldn't happen
		}
		window.parent.postMessage(
			JSON.stringify({
				type: 'webwork.interaction.submitted',
				status: parsed,
				frame: frame
			}),
			parentOrigin
		);
	}

	// fetch the problem-result-score and postMessage to parent
	const score = document.getElementById('problem-result-score')?.value;
	if (score) {
		window.parent.postMessage(
			JSON.stringify({
				type: 'webwork.interaction.attempt',
				status: score,
				frame: frame
			}),
			parentOrigin
		);
	}

	// set up listeners on knowl hints and solutions
	document.querySelectorAll('.knowl[data-type="hint"]').forEach((hint) => {
		hint.addEventListener('click', (event) => {
			window.parent.postMessage(
				JSON.stringify({
					type: 'webwork.interaction.hint',
					status: hint.classList[1],
					id: hint.dataset.bsTarget,
					frame: frame
				}),
				parentOrigin
			);
		});
	});

	document.querySelectorAll('.knowl[data-type="solution"]').forEach((solution) => {
		solution.addEventListener('click', (event) => {
			window.parent.postMessage(
				JSON.stringify({
					type: 'webwork.interaction.solution',
					status: solution.classList[1],
					id: solution.dataset.bsTarget,
					frame: frame
				}),
				parentOrigin
			);
		});
	});

	// set up listeners on the form for focus in/out, because they will bubble up to form
	// and because we don't want to juggle mathquill elements
	const form = document.getElementById('problemMainForm');
	let messageQueue = [];
	let messageTimer = null;

	function processMessageQueue() {
		// Process the original messages in the queue
		for (let message = messageQueue.pop(); message; message = messageQueue.pop()) {
			window.parent.postMessage(JSON.stringify(message), parentOrigin);
		}

		// Clear the message queue and timer
		messageQueue = [];
		clearTimeout(messageTimer);
		messageTimer = null;
	}

	// interrupt the blur/focus/blur/focus sequence caused by the toolbar
	function checkForButtonClick() {
		// using unshift so most recent is at the front
		if (messageQueue[0].type !== 'webwork.interaction.focus') return;

		// toolbar interaction focus/blur happens in between matching ids
		const id = messageQueue[0].id;
		if (messageQueue[3].id !== id) return;

		// toolbar interaction is focus/blur with same id, ends with answer id
		if (
			!messageQueue[1].id.endsWith(id) ||
			!messageQueue[2].id.endsWith(id) ||
			messageQueue[1].id !== messageQueue[2].id
		)
			return;

		// if we get here, we have a toolbar interaction
		const button = messageQueue[1].id.replace(`-${id}`, '');
		messageQueue.splice(0, 4, {
			type: 'webwork.interaction.toolbar',
			id: button,
			frame: frame
		});
	}

	function scheduleMessage(message) {
		messageQueue.unshift(message);

		if (messageQueue.length >= 4) {
			checkForButtonClick();
		}

		if (messageTimer) clearTimeout(messageTimer);
		messageTimer = setTimeout(processMessageQueue, 350);
	}

	form.addEventListener('focusin', (event) => {
		const id = event.composedPath().reduce((s, el) => (s ? s : el.id), '');
		if (id !== 'problem_body') {
			scheduleMessage({
				type: 'webwork.interaction.focus',
				id: id.replace('mq-answer-', ''),
				frame: frame
			});
		}
	});

	form.addEventListener('focusout', (event) => {
		const id = event.composedPath().reduce((s, el) => (s ? s : el.id), '');
		if (id !== 'problem_body') {
			scheduleMessage({
				type: 'webwork.interaction.blur',
				id: id.replace('mq-answer-', ''),
				frame: frame
			});
		}
	});

	// creditModal is PG-emitted UI (no renderer template / lib renders these IDs).
	// A PG macro somewhere in OPL emits #creditModal, #creditForm, #creditModalEmail,
	// #creditModalSubmitBtn into $problemText; this block wires up the modal
	// behavior. Owner of the macro is unknown as of 2026-04-29 — do not remove
	// without first confirming nothing in OPL still emits this content.
	// Architectural fix: move this glue into the emitting macro itself. Deferred
	// to upstream PG cleanup.
	const modal = document.getElementById('creditModal');
	if (modal) {
		const bsModal = new bootstrap.Modal(modal);
		bsModal.show();
		const creditForm = document.getElementById('creditForm');
		creditForm.addEventListener('submit', (event) => {
			event.preventDefault();
			const formData = new FormData();

			// get the sessionJWT from the document and add it to the form data
			const sessionJWT = document.getElementsByName('sessionJWT').item(0).value;
			formData.append('sessionJWT', sessionJWT);
			// get the email from the form and add it to the form data
			const email = document.getElementById('creditModalEmail').value;
			formData.append('email', email);
			const url = creditForm.action;
			const options = {
				method: 'POST',
				body: formData
			};
			fetch(url, options)
				.then((response) => {
					if (!response.ok) {
						console.error(response.statusText);
					}
					bsModal.hide();
				})
				.catch((error) => {
					console.error('Error:', error);
					bsModal.hide();
				});
		});

		// we also need to trigger the submit when the user clicks the button
		// or when they hit enter in the input field
		const creditButton = document.getElementById('creditModalSubmitBtn');
		creditButton.addEventListener('click', (event) => {
			creditForm.dispatchEvent(new Event('submit'));
		});
		const creditInput = document.getElementById('creditModalEmail');
		creditInput.addEventListener('keyup', (event) => {
			if (event.key === 'Enter') {
				creditForm.dispatchEvent(new Event('submit'));
			}
		});
	}

	// Resize: emit webwork.lifecycle.resize when body height settles. Native
	// ResizeObserver path introduced in WW3-R23; the iframe-resizer content
	// script is also loaded for integrators who haven't migrated yet (see
	// Renderer.pm third_party_js). Both protocols broadcast independently —
	// hosts listen to whichever they speak. MathJax renders math asynchronously
	// after page load — body height grows in stages — so debounce ~50ms to ship
	// only the settled value rather than every intermediate paint.
	if (typeof ResizeObserver !== 'undefined') {
		let resizeTimer = null;
		let lastHeight  = -1;
		const observer  = new ResizeObserver(() => {
			if (resizeTimer) clearTimeout(resizeTimer);
			resizeTimer = setTimeout(() => {
				const height = document.body.scrollHeight;
				if (height === lastHeight) return;
				lastHeight = height;
				window.parent.postMessage(
					JSON.stringify({
						type: 'webwork.lifecycle.resize',
						frame: frame,
						height: height
					}),
					parentOrigin
				);
			}, 50);
		});
		observer.observe(document.body);
	}
})();

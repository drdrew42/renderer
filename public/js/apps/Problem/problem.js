(() => {
	// Activate the popovers in the results table.
	document.querySelectorAll('.attemptResults .answer-preview[data-bs-toggle="popover"]')
		.forEach((preview) => {
			if (preview.dataset.bsContent)
				new bootstrap.Popover(preview);
		});
	
	// if there is a JWTanswerURLstatus element, report it to parent
	const status = document.getElementById('JWTanswerURLstatus')?.value;
	if (status) {
		console.log("problem status updated:", JSON.parse(value));
		window.parent.postMessage(value, '*');
	}
	
	// fetch the problem-result-score and postMessage to parent
	const score = document.getElementById('problem-result-score')?.value;
	if (score) {
		window.parent.postMessage(JSON.stringify({
			type: 'webwork.interaction.attempt',
			status: score,
		}), '*');
	}

	// set up listeners on knowl hints and solutions
	document.querySelectorAll('.knowl[data-type="hint"]').forEach((hint) => {
		hint.addEventListener('click', (event) => {
			window.parent.postMessage(JSON.stringify({
				type: 'webwork.interaction.hint',
				status: hint.classList[1],
				id: hint.dataset.bsTarget,
			}), '*');
		});
	});

	document.querySelectorAll('.knowl[data-type="solution"]').forEach((solution) => {
		solution.addEventListener('click', (event) => {
			window.parent.postMessage(JSON.stringify({
				type: 'webwork.interaction.solution',
				status: solution.classList[1],
				id: solution.dataset.bsTarget,
			}), '*');
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
			window.parent.postMessage(JSON.stringify(message), '*');
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
		if (!messageQueue[1].id.endsWith(id) 
			|| !messageQueue[2].id.endsWith(id)
			|| messageQueue[1].id !== messageQueue[2].id) return;
		
		// if we get here, we have a toolbar interaction
		const button = messageQueue[1].id.replace(`-${id}`, '');
		messageQueue.splice(0, 4, {
			type: 'webwork.interaction.toolbar',
			id: button,
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
		const id = event.composedPath().reduce((s, el) => s ? s : el.id, '');
		if (id !== 'problem_body') {
			scheduleMessage({
				type: 'webwork.interaction.focus',
				id: id.replace('mq-answer-', ''),
			});
		}
	});
	
	form.addEventListener('focusout', (event) => {
		const id = event.composedPath().reduce((s, el) => s ? s : el.id, '');
		if (id !== 'problem_body') {
			scheduleMessage({
				type: 'webwork.interaction.blur',
				id: id.replace('mq-answer-', ''),
			});
		}
	});

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
				body: formData,
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
})();

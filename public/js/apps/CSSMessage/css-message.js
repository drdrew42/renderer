window.addEventListener('message', event => {
	let message;
	try {
		message = JSON.parse(event.data);
	}
	catch (e) {
		if (!event.data.startsWith('[iFrameSizer]')) console.warn('CSSMessage: message not JSON', event.data);
		return;
	}

	if (message.hasOwnProperty('elements')) {
		message.elements.forEach((incoming) => {
			let elements;
			if (incoming.hasOwnProperty('selector')) {
				elements = window.document.querySelectorAll(incoming.selector);
				if (incoming.hasOwnProperty('style')) {
					elements.forEach(el => { el.style.cssText = incoming.style });
				}
				if (incoming.hasOwnProperty('class')) {
					elements.forEach(el => { el.className = incoming.class });
				}
			}
		});
		event.source.postMessage(JSON.stringify({ type: "webwork.css.update", update: "elements updated"}), event.origin);
	}

	if (message.hasOwnProperty('templates')) {
		message.templates.forEach((cssString) => {
			const element = document.createElement('style');
			element.innerText = cssString;
			document.head.insertAdjacentElement('beforeend', element);
		});
		event.source.postMessage(JSON.stringify({ type: "webwork.css.update", update: "templates updated"}), event.origin);
	}

	if (message.hasOwnProperty('showSolutions')) {
		const elements = Array.from(window.document.querySelectorAll('.knowl[data-type="solution"]'));
		const solutions = elements.map(el => el.dataset.knowlContents);
		event.source.postMessage(JSON.stringify({ type: "webwork.content.solutions", solutions: solutions }), event.origin);
	}

	if (message.hasOwnProperty('showHints')) {
		const elements = Array.from(window.document.querySelectorAll('.knowl[data-type="hint"]'));
		const hints = elements.map(el => el.dataset.knowlContents);
		event.source.postMessage(JSON.stringify({ type: "webwork.content.hints", hints: hints }), event.origin);
	}
});

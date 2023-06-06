window.document.getElementsByName('JWTanswerURLstatus').forEach(e => {
	console.log("response message ", JSON.parse(e.value));
	window.parent.postMessage(e.value, '*');
});

window.addEventListener('message', event => {
	let message;
	try {
		message = JSON.parse(event.data);
	}
	catch (e) {
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
		event.source.postMessage('updated elements', event.origin);
	}

	if (message.hasOwnProperty('templates')) {
		message.templates.forEach((cssString) => {
			const element = document.createElement('style');
			element.innerText = cssString;
			document.head.insertAdjacentElement('beforeend', element);
		});
		event.source.postMessage('updated templates', event.origin);
	}

	if (message.hasOwnProperty('showSolutions')) {
		const elements = Array.from(window.document.querySelectorAll('.knowl[data-type="solution"]'));
		const solutions = elements.map(el => el.dataset.knowlContents);
		event.source.postMessage(JSON.stringify({ solutions: solutions }), event.origin);
	}
});

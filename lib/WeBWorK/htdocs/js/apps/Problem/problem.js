(() => {
	// Activate the popovers in the results table.
	document.querySelectorAll('.attemptResults .answer-preview[data-bs-toggle="popover"]')
		.forEach((preview) => {
			if (preview.dataset.bsContent)
				new bootstrap.Popover(preview);
		});
})();

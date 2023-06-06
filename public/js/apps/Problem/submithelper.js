(() => {
	let problemForm = document.getElementById('problemMainForm')
	if (!problemForm) return;
	problemForm.querySelectorAll('input[type="submit"]').forEach(button => {
		button.addEventListener('click', () => {
			// Keep ONLY the last button clicked.
			problemForm.querySelectorAll('input[type="submit"]').forEach(clean => {
				clean.classList.remove('btn-clicked');
			});
			button.classList.add("btn-clicked");
		})
	})
})

window.addEventListener('load', () => {
  let problemForm = document.getElementById('problemMainForm')
  if (!problemForm) {console.log("could not find form!"); return;}
  problemForm.querySelectorAll('.btn-primary').forEach( button => {
    button.addEventListener('click', () => {
      // debounce means we need to keep ONLY the last button clicked
      problemForm.querySelectorAll('.btn-primary').forEach( clean => {
        clean.classList.remove('btn-clicked');
      }); // clear all clicks
      button.classList.add("btn-clicked");
      console.log("clicked: ", button);
    })
  })
})

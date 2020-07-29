window.addEventListener('load', () => {
  let problemForm = document.getElementById('problemMainForm')
  if (!problemForm) {console.log("could not find form!"); return;}
  problemForm.querySelectorAll('.btn-primary').forEach( button => {
    button.addEventListener('click', () => {
      button.classList.add("btn-clicked");
      console.log("clicked: ", button);
    })
  })
})

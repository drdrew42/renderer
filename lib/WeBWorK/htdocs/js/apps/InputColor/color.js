/*
 * color.js
 *
 * for coloring the input elements with the proper color based on whether they are correct or incorrect
 *
 * Originally by ghe3
 * Edited by dpvc 2014-08
 */

 function color_inputs(correct,incorrect) {
   correct.forEach( (ansName)=> {
     document.querySelectorAll("input[name*="+ansName+"]").forEach((e,i)=>{
       e.className += " correct";
     });
   });
   incorrect.forEach( (ansName)=> {
     document.querySelectorAll("input[name*="+ansName+"]").forEach((e,i)=>{
       e.className += " incorrect";
     });
   });
 }

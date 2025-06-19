function updateDBsubject() {
    var subjectSelect = window.document.getElementById('db-subject');
    var subjects = Object.keys(taxo) || [];
    addOptions(subjectSelect, subjects);
}

function updateDBchapter() {
    var subjectSelect = window.document.getElementById('db-subject');
    var subject = subjectSelect.options[subjectSelect.selectedIndex]?.value;
    var chapterSelect = window.document.getElementById('db-chapter')
    var chapters = (taxo[subject]) ? Object.keys(taxo[subject]) : [];
    addOptions(chapterSelect, chapters);
}

function updateDBsection() {
    var subjectSelect = window.document.getElementById('db-subject');
    var subject = subjectSelect.options[subjectSelect.selectedIndex]?.value;
    var chapterSelect = window.document.getElementById('db-chapter');
    var chapter = chapterSelect.options[chapterSelect.selectedIndex]?.value;
    var sectionSelect = window.document.getElementById('db-section');
    var sections = (taxo[subject] && taxo[subject][chapter]) ? taxo[subject][chapter] : [];
    addOptions(sectionSelect, sections);
}

function addOptions(selectElement, optionsArray) {
    if (selectElement.innerHTML) { selectElement.innerHTML = '' }
    optionsArray.forEach(function (opt) {
        var option = document.createElement('option');
        option.value = opt;
        option.text = opt;
        selectElement.add(option);
    });
    var emptyOption = document.createElement('option');
    emptyOption.value = '';
    emptyOption.text = 'blank';
    selectElement.add(emptyOption, 0);
    selectElement.selectedIndex = 0;
}

function submitTags(e) {
    e.preventDefault();
    var formData = new FormData(e.target);

    // disassemble the Description
    formData = parseStringAndAppend(formData, 'Description');

    // disassemble the list of keywords
    formData = parseStringAndAppend(formData, 'Keywords');

    // disassemble any resources
    formData = parseStringAndAppend(formData, 'Resources');

    var params = {
        body: formData,
        method: 'post'
    };
    fetch(e.target.action, params)
    .then( function (resp) {
        if (resp.ok) {
            return resp.json();
        } else {
            throw new Error("Something went wrong: " + resp.statusText);
        }
    })
    .then( d => updateMetadata(d) )
    .catch( e => {console.log(e); alert(e.message);} );
}

// uses the convention that tags want these arrays as lowercase
// UI uses the joined string in key with first-capital
function parseStringAndAppend(formData, elementName) {
    var string = window.document.getElementsByName(elementName)[0].value;
    if (string && string !== '') {
        var array = string.split(',').map(el => el.trim());
        array.forEach(item => formData.append(elementName.toLowerCase(), item));
        formData.delete(elementName);
    }
    return formData;
}

updateDBsubject();
window.document.getElementById('problem-tags').addEventListener('submit', submitTags);
// pass the form to use for updating and a callback for updating back-navigation
// examples for this callback are provided: `diveIn` and `backOut`
function updateBrowser(formId, updateBackNav) {
    var form = window.document.getElementById(formId);
    var target = form.action;
    var select = form.getElementsByTagName('select')[0]; // each form has only one <select> element
    var option = select.options[select.selectedIndex];
    var value = option.value;
    var formData = new FormData();
    var processData; 

    if (value.startsWith('/')) { value = value.replace('/', '') } // replaces first instance only
    if (value.match(/\/$/)) { 
        formData.set('maxDepth', 1);
        formData.set('basePath', value);
        processData = function (data) {
            updateFileList(data);
            updateBackNav(option.text);
        };
    } else if (value.match(/\.pg$/)) {
        target = '/render-api/';
        formData.set('sourceFilePath', value);
        formData.set('randomSeed', value);
        formData.set('outputFormat', 'static');
        formData.set('format', 'json');
        formData.set('showHints', 1);
        formData.set('showSolutions', 1);
        processData = function (data) {
            updateIframe(data.renderedHTML);
            updateMetadata(data);
        }
    } else {
        // default back to the root
        resetBackNav();
        return;
    }

    var params = {
        body: formData,
        method: 'post'
    };
    fetch(target, params)
    .then( function(resp) {
        if (resp.ok) {
            return resp.json();
        } else {
            throw new Error("Something went wrong: " + resp.statusText);
        }
    })
    .then( processData )
    .catch( function(e) {
        console.log(e);
        alert(e.message);
    });
}

// use the response to update the file browser
function updateFileList(data) {
    var select = window.document.getElementById('file-list');
    select.innerHTML = '';
    for (var key in data) {
        var opt = document.createElement('option');
        if (key.match(/\./)) { opt.className = (key.match(/\.pg$/)) ? 'pg-file' : 'other-file'; }
        opt.text = key;
        opt.value = data[key];
        select.add(opt);
    }
}

// callback to extend the back-navigation
function diveIn(updatePath) {
    var select = window.document.getElementById('back-nav');
    var current = select.options[0];
    var newOption = document.createElement('option');
    newOption.text = `${current.text}${updatePath}/`;
    newOption.value = `${current.value}${updatePath}/`;
    select.add(newOption, 0);
    select.selectedIndex = 0;
}

// callback to retract the back-navigation
function backOut(updatePath) {
    var select = window.document.getElementById('back-nav');
    while (select.selectedIndex !== 0) {
        select.remove(0);
    }
}

// reset the back-navigation
function resetBackNav() {
    var data = {
        Contrib: 'Contrib/',
        Library: 'Library/',
        Pending: 'Pending/',
        private: 'private/',
    }
    updateFileList(data);

    var select = window.document.getElementById('back-nav');
    select.selectedIndex = select.options.length - 1;
    backOut('/');
}

// in case the raw metadata text is parsed incorrectly
// display it as text
function updateRawMetadata(text) {
    var container = window.document.getElementById('raw-metadata');
    text = text.replace(/\n/g, '<BR>');
    text = text.replace(/#/g, '');
    container.innerHTML = text;
}

function updateIframe(html) {
    var container = window.document.getElementById('rendered-problem');
    container.srcdoc = html;
}

function mergeArrays() {
    var merged = [];
    var args = Array.prototype.slice.call(arguments);
    args.forEach( (arg) => merged = merged.concat(arg) );
    return merged.filter((el, ind, arr) => (el && arr.indexOf(el) === ind));
}

function updateMetadata(data) {
    // obscene, but merges the two sources and eliminates duplicates, ignores undef
    data.tags.resources = mergeArrays(data.tags.resources, data.resources, data.pgResources);

    if (data.tags.isplaceholder === 1) {
        // reset all form-fields
        var tagContainer = window.document.getElementById('tag-wrapper');
        updateEach(tagContainer, {Resources: data.tags.resources.join(', ')});
        var flagContainer = window.document.getElementById('flags-wrapper');
        updateEach(flagContainer, {});
        updateRawMetadata('');

        alert(`${data.tags.file} is a placeholder - do not set tags!`);
        console.log(data);
        return; // bow out
    }

    // make sure the tags form is matched to the right pg file
    var pathfield = window.document.getElementById('tag-filename');
    pathfield.setAttribute('value', data.tags.file);

    if (data.raw_metadata_text) {
        updateRawMetadata(data.raw_metadata_text);
    } else {
        updateRawMetadata('');
    }
    // metadata is spread across the response object
    // form data is grouped by 'location' in the response
    if (data.tags) {
        var tagContainer = window.document.getElementById('tag-wrapper');
        console.log("METADATA: ", data);
        // description is an array of text, one entry per line
        data.tags.Description = data.tags.description.join("\n");
        // keywords is an array of strings
        data.tags.Keywords = data.tags.keywords.join(', ');
        data.tags.Resources = data.tags.resources.join(', ');
        updateEach(tagContainer, data.tags);
    }

    if (data.flags) {
        var flagContainer = window.document.getElementById('flags-wrapper');
        updateEach(flagContainer, data.flags);
    }
}

// update form fields from response data
// @param container - the html parent
// @param info - an object containing keys corresponding to the children of `container`
function updateEach(container, info) {
    for (i = 0; i < container.children.length; i++) {
        var field = container.children[i].children[1];
        var fieldName = field.getAttribute('name');
        // console.log(`name: ${fieldName}; value: ${info[fieldName]}`);
        if (field.getAttribute('type') === 'checkbox') {
            if (info[fieldName] && info[fieldName] == 1) { // should accept either 1 or "1"
                field.setAttribute('checked', 'checked');
            } else {
                field.removeAttribute('checked');
            }
        } else {
            field.value = info[fieldName] || '';
            // when value for dropdown is not available - reset to blank and log
            if (field.value !== '' && field.value !== info[fieldName]) {
                console.log(`Cannot set ${fieldName} = ${info[fieldName]}`);
                field.value = '';
            }
        }
        if (field.tagName === 'SELECT' && field.onchange) { field.onchange() };
    }
}
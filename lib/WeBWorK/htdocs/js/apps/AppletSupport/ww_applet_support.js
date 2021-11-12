// ################################################################################
// # WeBWorK Online Homework Delivery System
// # Copyright &copy; 2000-2021 The WeBWorK Project, https://github.com/openwebwork
// #
// # This program is free software; you can redistribute it and/or modify it under
// # the terms of either: (a) the GNU General Public License as published by the
// # Free Software Foundation; either version 2, or (at your option) any later
// # version, or (b) the "Artistic License" which comes with this package.
// #
// # This program is distributed in the hope that it will be useful, but WITHOUT
// # ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
// # FOR A PARTICULAR PURPOSE.  See either the GNU General Public License or the
// # Artistic License for more details.
// ################################################################################

// List of web applets on the page.
window.ww_applet_list = {};

// Utility functions

// Dummy function provided to prevent console errors for problems written for lecacy code.
function applet_loaded() {}

function getApplet(appletName) {
	return window[appletName];
}

// Determine whether an XML string has been base64 encoded.
// This returns false if the string is empty, or if it contains a < or > character.
// The empty string is not a base64 string, and
// base64 can't contain < or > and xml strings contain lots of them.
function base64Q(str) {
	return str && !/[<>]+/.exec(str);
}

// Get Question Element in problemMainForm by name
function getQE(name1) {
	const obj = document.getElementById(name1) ?? document.problemMainForm[name1];
	if (!obj || obj.name != name1) {
		console.log("Can't find element " + name1);
	} else {
		return obj;
	}
}

function getQuestionElement(name1) {
	return getQE(name1);
}

// WW_Applet class definition
class ww_applet {
	constructor(appletName) {
		this.appletName         = appletName;
		this.type               = '';
		this.initialState       = '';
		this.configuration      = '';
		this.getStateAlias      = '';
		this.setStateAlias      = '';
		this.setConfigAlias     = '';
		this.getConfigAlias     = '';
		this.submitActionScript = '';
		this.onInit             = 0;
		this.setupComplete      = false;
	}

	// Make sure that the applet has this function available
	methodDefined(methodName) {
		const applet = getApplet(this.appletName);
		if (methodName && typeof(applet[methodName]) == "function") return true;
		return false;
	}

	// CONFIGURATIONS
	// Configurations are "permanent"
	setConfig() {
		const applet = getApplet(this.appletName);
		try {
			if (this.methodDefined(this.setConfigAlias))
				applet[this.setConfigAlias](this.configuration);
		} catch(e) {
			console.log("Error in configuring applet " + this.appletName + " using command " + this.setConfigAlias + " : " + e);
		}
	}

	// Gets the configuration from the applet.
	getConfig() {
		const applet = getApplet(this.appletName);
		try {
			if (this.methodDefined(this.getConfigAlias))
				console.log(applet[this.getConfigAlias]());
		} catch(e) {
			console.log("Error in getting configuration from applet " + this.appletName + " " + e);
		}
	}

	// Set the state stored on the HTML page
	setHTMLAppletState(newState) {
		if (typeof(newState) === 'undefined') newState = "<xml>restart_applet</xml>";
		const stateInput = ww_applet_list[this.appletName].stateInput;
		getQE(stateInput).value = newState;
		getQE("previous_" + stateInput).value = newState;
	}

	// STATE:
	// State can vary as the applet is manipulated.  It is reset from the questions state values.
	setState(state) {
		const applet = getApplet(this.appletName);

		// Obtain the state which will be sent to the applet and if it is encoded place it in plain xml text.
		// Communication with the applet is in plain text, not in base64 code.

		if (!state) {
			// Hidden answer box preserving applet state
			const ww_preserve_applet_state = getQE(this.stateInput);
			state = ww_preserve_applet_state.value;
		}

		if (base64Q(state)) state = atob(state);

		// Handle the exceptional cases:
		// If the state is blank, undefined, or explicitly defined as restart_applet,
		// then we will not simply be restoring the state of the applet from HTML "memory".
		//
		// 1. For a restart we wipe the HTML state cache so that we won't restart again.
		// 2. In the other "empty" cases we attempt to replace the state with the contents of the
		//    initialState variable.

		// Exceptional cases
		if (state.match(/^<xml>restart_applet<\/xml>/) ||
			state.match(/^\s*$/) ||
			state.match(/^<xml>\s*<\/xml>/)) {

			if (typeof(this.initialState) == "undefined") { this.initialState = "<xml></xml>"; }
			if (this.initialState.match(/^<xml>\s*<\/xml>/) || this.initialState.match(/^\s*$/)) {
				// Set the saved state to the empty state, so that the submit action will not be overridden by
				// restart_applet.
				this.setHTMLAppletState("<xml></xml>");

				// Don't call the setStateAlias function.
				// Quit because we know we will not transmitting any starting data to the applet
				return;
			} else {
				state = this.initialState;
				if (base64Q(state)) state = atob(state);

				// Store the state in the HTML variables just for safety
				this.setHTMLAppletState(this.initialState);

				// If there was a viable state in the initialState variable we can
				// now continue as if we had found a valid state in the HTML cache.
			}
		}

		// State MUST be an xml string in plain text
		if (state.match(/\<xml/i) || state.match(/\<\?xml/i)) {
			try {
				if (this.methodDefined(this.setStateAlias)) {
					applet[this.setStateAlias](state);
				}
			} catch(err) {
				console.log("Error in setting state of " + this.appletName + " using command " +
					this.setStateAlias + " : " + err + err.number + err.description);
			}
		}
	}

	getState() {
		let state = "<xml>foobar</xml>";
		const applet = getApplet(this.appletName);

		try {
			if (this.methodDefined(this.getStateAlias)) {
				state = applet[this.getStateAlias](); // Get state in xml format
			} else {
				state ="<xml></xml>";
			}
		} catch (e) {
			console.log("Error in getting state from applet " + this.appletName + " " + e);
		}

		// Replace state by encoded version
		if (!base64Q(state)) state = btoa(state);

		// Save the state to the hidden input preserving applet state
		getQE(this.stateInput).value = state;
	}

	submitAction() {
		// Find the hidden input element preserving applet state and get its value.
		const ww_preserve_applet_state = getQE(this.stateInput);

		// Check to see if we want to restart the applet
		if (ww_preserve_applet_state.value.match(/^<xml>restart_applet<\/xml>/)) {
			// Replace the saved state with <xml>restart_applet</xml>
			this.setHTMLAppletState();
			return;
		}

		// If we are not restarting the applet, then save the state and submit.

		// Have ww_applet retrieve state from applet and store in HTML cache
		this.getState();

		eval(this.submitActionScript);

		// Because the state has not always been perfectly preserved when storing the state in text
		// area boxes we take a "belt && suspenders" approach by converting the value of the text
		// area state cache to base64 form.
		if (!base64Q(ww_preserve_applet_state.value))
			ww_preserve_applet_state.value = btoa(ww_preserve_applet_state.value);
	}

	safe_applet_initialize() {
		// Configure the applet.
		try {
			this.setConfig();
		} catch(e) {
			console.log("Unable to configure " + this.appletName + ":\n " + e);
		}

		// Set the applet state.
		try {
			this.setState();
		} catch(e) {
			console.log("*Unable to set the state for " + this.appletName + ":\n " + e);
		}
	}
}

(() => {
	// This should be the only ggbOnInit method defined.  Unfortunately some older problems define a
	// ggbOnInit so we check for that here.  Those problems should be updated, and newly written
	// problems should not define a javascript function by that name.
	// This caches the ggbOnInit from the problem, and calls it in the ggbOnInit function defined
	// here.  This will only work if there is only one of these old problems on the page.
	let ggbOnInitFromProblem = window.ggbOnInit;
	const wwGGBOnInit = (appletName) => {
		if (typeof ggbOnInitFromProblem == 'function') {
			ggbOnInitFromProblem(appletName);
		}
		if (appletName in ww_applet_list && ww_applet_list[appletName].onInit &&
			ww_applet_list[appletName].onInit != 'ggbOnInit') {
			if (window[ww_applet_list[appletName].onInit] &&
				typeof(window[ww_applet_list[appletName].onInit]) == 'function') {
				window[ww_applet_list[appletName].onInit](appletName);
			} else {
				eval(ww_applet_list[appletName].onInit);
			}
		}
	};
	window.ggbOnInit = wwGGBOnInit;

	const addProblemFormSubmitHandler = (form) => {
		if (form.submitHandlerInitialized) return;
		form.submitHandlerInitialized = true;

		// Connect the submit action handler to the form.
		form.addEventListener('submit', () => {
			for (const appletName in ww_applet_list) {
				ww_applet_list[appletName].submitAction();
			}
		});
	};

	// Initialize applet support and the applets.
	function initializeAppletSupport() {
		const problemForm = document.problemMainForm ?? document.gwquiz;
		if (problemForm) {
			if (problemForm instanceof HTMLCollection) {
				for (const form of problemForm) addProblemFormSubmitHandler(form);
			} else {
				addProblemFormSubmitHandler(problemForm);
			}
		}

		if (window.ggbOnInit !== wwGGBOnInit) {
			ggbOnInitFromProblem = window.ggbOnInit;
			window.ggbOnInit = wwGGBOnInit;
		}

		for (const appletName in ww_applet_list) {
			const container = document.getElementById(appletName);

			// Delete applets in the list that are no longer on the page.
			if (!container) {
				delete document[appletName];
				delete ww_applet_list[appletName];
				continue;
			}

			if (ww_applet_list[appletName].setupComplete) continue;
			ww_applet_list[appletName].setupComplete = true;

			const resetButton = document.querySelector(`.applet-reset-btn[data-applet-name="${appletName}"]`);
			if (resetButton && problemForm) {
				let containingForm = null;
				if (problemForm instanceof HTMLCollection) {
					for (const form of problemForm) {
						if (form.querySelector(`.applet-reset-btn[data-applet-name="${appletName}"]`)) {
							containingForm = form;
							break;
						}
					}
				} else {
					if (problemForm.querySelector(`.applet-reset-btn[data-applet-name="${appletName}"]`))
						containingForm = problemForm;
				}
				if (containingForm) {
					resetButton.addEventListener('click', () => {
						ww_applet_list[appletName].setHTMLAppletState();
						let previewAnswerButton = null;
						for (const control of containingForm.elements) {
							if (control.name === 'previewAnswers') {
								previewAnswerButton = control;
								break;
							}
						}
						previewAnswerButton?.click();
					});
				}
			}

			// Create and initialize geogebra applet objects.
			if (ww_applet_list[appletName].type == 'geogebraweb') {
				const ggbApplet = new GGBApplet(Object.assign({}, container.dataset), true);
				ggbApplet.setHTML5Codebase('https://geogebra.org/apps/latest/web3d/');
				ggbApplet.inject(appletName);
			}

			// If onInit is defined, then the onInit function will handle the initialization.
			if (!ww_applet_list[appletName].onInit) {
				ww_applet_list[appletName].safe_applet_initialize();
			}
		}
	}

	window.addEventListener('PGContentLoaded', initializeAppletSupport);
	window.addEventListener('DOMContentLoaded', initializeAppletSupport);
})();

// Polyfill for IE >= 9.
if (!Object.entries) Object.entries = function(o) {
    var p = Object.keys(o), i = p.length, r = new Array(i);
    while (i--) r[i] = [p[i], o[p[i]]];
    return r;
};

// initialize MathQuill
var MQ = MathQuill.getInterface(2);
answerQuills = {};

function createStaticQuill() {
	var answerLabel = this.id.replace(/^MaThQuIlL_/, "");
	var input = $("#" + answerLabel);
	var inputType = input.attr('type');
	if (typeof(inputType) != 'string' || inputType.toLowerCase() !== "text") return;

	var answerQuill = $("<span id='mq-answer-" + answerLabel + "'></span>");
	answerQuill.input = input;
	answerQuill.latexInput = $(this);

	input.after(answerQuill);

	answerQuill.mathField = MQ.StaticMath(answerQuill[0]);

	answerQuill.textarea = answerQuill.find("textarea");

	answerQuill.hasFocus = false;

	answerQuill.mathField.latex(answerQuill.latexInput.val());

	// Give the mathquill answer box the correct/incorrect colors.
	setTimeout(function() {
		if (answerQuill.input.hasClass('correct')) answerQuill.addClass('correct');
		else if (answerQuill.input.hasClass('incorrect')) answerQuill.addClass('incorrect');
	}, 300);

	// Replace the result table correct/incorrect javascript that gives focus
	// to the original input, with javascript that gives focus to the mathquill
	// answer box.
	var resultsTableRows = jQuery("table.attemptResults tr:not(:first-child)");
	if (resultsTableRows.length)
	{
		resultsTableRows.each(function()
			{
				var result = $(this).find("td > a");
				var href = result.attr('href');
				if (result.length && href !== undefined && href.indexOf(answerLabel) != -1)
				{
					// Set focus to the mathquill answer box if the correct/incorrect link is clicked.
					result.attr('href',
						"javascript:void(window.answerQuills['" + answerLabel + "'].textarea.focus())");
				}
			}
		);
	}

	answerQuills[answerLabel] = answerQuill;
}

$(function() { $("[id^=MaThQuIlL_]").each(createStaticQuill); });
$(function() { $("[id^=AnSwEr]").each( (i,e)=>{e.disabled=true;} )});

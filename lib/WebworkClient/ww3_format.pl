{
	answerTemplate => '$answerTemplate',
	scoreSummary => '$scoreSummary',

	problemText => <<'ENDPROBLEMTEMPLATE'
$problemHeadText
<form class="problem-main-form" name="problemMainForm" action="$FORM_ACTION_URL" method="post">
	<div class="problem-content" $PROBLEM_LANG_AND_DIR>
		$problemText
	</div>

	<input type="hidden" name="answersSubmitted" value="1">
	<input type="hidden" name="sourceFilePath" value = "$sourceFilePath">
	<input type="hidden" name="problemSourceURL" value = "$problemSourceURL">
	<input type="hidden" name="problemSource" value="$encoded_source">
	<input type="hidden" name="problemSeed" value = "$problemSeed">
	<input type="hidden" name="language" value="$formLanguage">
	<input type="hidden" name="showSummary" value="$showSummary">
</form>
ENDPROBLEMTEMPLATE
};

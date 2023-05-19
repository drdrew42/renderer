{
	answerTemplate => '$answerTemplate',
	scoreSummary => '$scoreSummary',

	problemText => <<'ENDPROBLEMTEMPLATE'
$problemHeadText
<form class="problem-main-form" name="problemMainForm" action="$FORM_ACTION_URL" method="post">
	<div class="problem-content" $PROBLEM_LANG_AND_DIR>
		$problemText
	</div>

	<input type="hidden" name="sessionJWT" value="$sessionJWT">
</form>
ENDPROBLEMTEMPLATE
};

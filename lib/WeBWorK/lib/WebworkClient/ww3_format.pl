$ww3_format = <<'ENDPROBLEMTEMPLATE';
<!DOCTYPE html>
<html $COURSE_LANG_AND_DIR>
  <div class="container-fluid">
    <div class="row-fluid">
      <div class="span12 problem">
		    $answerTemplate
        $color_input_blanks_script
        <form id="problemMainForm" class="problem-main-form" name="problemMainForm" action="$FORM_ACTION_URL" method="post" onsubmit="submitAction()">
          <div id="problem_body" class="problem-content" $PROBLEM_LANG_AND_DIR>
            $problemText
          </div>
          $scoreSummary
          $LTIGradeMessage

          <input type="hidden" name="answersSubmitted" value="1">
          <input type="hidden" name="sourceFilePath" value = "$sourceFilePath">
          <input type="hidden" name="problemSourceURL" value = "$problemSourceURL">
          <input type="hidden" name="problemSource" value="$encoded_source">
          <input type="hidden" name="problemSeed" value = "$problemSeed">
          <input type="hidden" name="language" value="$formLanguage">
          <input type="hidden" name="showSummary" value="$showSummary">
          <p>

            <input type="submit" name="previewAnswers"  value="$STRING_Preview" />
            <input type="submit" name="submitAnswers" value="$STRING_Submit"/>
            <input type="submit" name="showCorrectAnswers" value="$STRING_ShowCorrect"/>
          </p>
        </form>
      </div>
    </div>
  </div>
</html>

ENDPROBLEMTEMPLATE

$ww3_format;

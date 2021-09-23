# The json output format needs to collect the data differently than
# the other formats. It will return an array which alternates between
# key-names and values, and each relevant value will later undergo
# variable interpolation.

# Most parts which need variable interpolation end in "_VI".
# Other parts which need variable interpolation are:
#	hidden_input_field_*
#	real_webwork_*

@pairs_for_json = (
  "head_part001_VI", "<!DOCTYPE html>\n" . '<html $COURSE_LANG_AND_DIR>' . "\n"
);

$nextBlock = <<'ENDPROBLEMTEMPLATE';
<head>
<meta charset='utf-8'>
<base href="TO_SET_LATER_SITE_URL">
<link rel="shortcut icon" href="$webwork_htdocs_url/images/favicon.ico"/>
ENDPROBLEMTEMPLATE

push( @pairs_for_json, "head_part010", $nextBlock );

$nextBlock = <<'ENDPROBLEMTEMPLATE';
<!-- CSS Loads -->
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/jqueryui/1.12.1/jquery-ui.min.css" integrity="sha512-aOG0c6nPNzGk+5zjwyJaoRUgCdOrfSDhmMID2u4+OIslr0GjpLKo7Xm0Ao3xmpM4T8AmIouRkqwj1nrdVsLKEQ==" crossorigin="anonymous" />
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/5.15.3/css/all.min.css" integrity="sha512-iBBXm8fW90+nuLcSKlbmrPcLa0OT92xO1BIsZ+ywDWZCvqsWgccV3gFoRBv0z+8dLJgyAHIhR35VZc2oM/gI1w==" crossorigin="anonymous" />
<link rel="stylesheet" type="text/css" href="$webwork_htdocs_url/js/vendor/bootstrap/css/bootstrap.min.css"/>
<link rel="stylesheet" type="text/css" href="$webwork_htdocs_url/js/vendor/bootstrap/css/bootstrap-responsive.min.css"/>
<link rel="stylesheet" type="text/css" href="$webwork_htdocs_url/css/bootstrap.sub.css"/>
<link rel="stylesheet" type="text/css" href="$webwork_htdocs_url/themes/math4/math4.css"/>
<link rel="stylesheet" type="text/css" href="$webwork_htdocs_url/css/knowlstyle.css"/>

<link rel="stylesheet" type="text/css" href="$webwork_htdocs_url/js/apps/MathQuill/mathquill.css"/>
<link rel="stylesheet" type="text/css" href="$webwork_htdocs_url/js/apps/MathQuill/mqeditor.css"/>
<link rel="stylesheet" type="text/css" href="$webwork_htdocs_url/js/apps/ImageView/imageview.css"/>

ENDPROBLEMTEMPLATE

push( @pairs_for_json, "head_part100", $nextBlock );

$nextBlock = <<'ENDPROBLEMTEMPLATE';
<!-- JS Loads -->
<script>function submitAction() {}</script>
<script src="https://polyfill.io/v3/polyfill.min.js?features=es6" defer></script>
<script type="text/javascript" src="$webwork_htdocs_url/js/apps/MathJaxConfig/mathjax-config.js" defer></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/mathjax/3.1.2/es5/tex-chtml.min.js" defer integrity="sha512-OEN4O//oR+jeez1OLySjg7HPftdoSaKHiWukJdbFJOfi2b7W0r0ppziSgVRVNaG37qS1f9SmttcutYgoJ6rwNQ==" crossorigin="anonymous"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/jquery/3.6.0/jquery.min.js" integrity="sha512-894YE6QWD5I59HgZOGReFYm4dnWc1Qt5NtvYSaNcOP+u1T9qYdvdihz0PPSiiqn/+/3e7Jo4EaG7TubfWGUrMQ==" crossorigin="anonymous"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/jqueryui/1.12.1/jquery-ui.min.js" integrity="sha512-uto9mlQzrs59VwILcLiRYeLKPPbS/bT71da/OEBYEwcdNUk8jYIy+D176RYoop1Da+f9mvkYrmj5MCLZWEtQuA==" crossorigin="anonymous"></script>
<script src="$webwork_htdocs_url/js/vendor/bootstrap/js/bootstrap.js"></script>
<script type="text/javascript" src="$webwork_htdocs_url/js/apps/InputColor/color.js"></script>
<script type="text/javascript" src="$webwork_htdocs_url/js/apps/Base64/Base64.js"></script>
<script type="text/javascript" src="$webwork_htdocs_url/js/legacy/vendor/knowl.js"></script>
<script type="text/javascript" src="$webwork_htdocs_url/js/apps/ImageView/imageview.js"></script>
<script type="text/javascript" src="$webwork_htdocs_url/themes/math4/math4.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/iframe-resizer/4.3.1/iframeResizer.contentWindow.min.js" integrity="sha512-qw2bX9KUhi7HLuUloyRsvxRlWJvj0u0JWVegc5tf7qsw47T0pwXZIk1Kyc0utTH3NlrpHtLa4HYTVUyHBr9Ufg==" crossorigin="anonymous"></script>

<script type="text/javascript" src="$webwork_htdocs_url/js/apps/MathQuill/mathquill.min.js" defer></script>
<script type="text/javascript" src="$webwork_htdocs_url/js/apps/MathQuill/mqeditor.js" defer></script>
<script type="text/javascript" src="$webwork_htdocs_url/js/submithelper.js"></script>
ENDPROBLEMTEMPLATE

push( @pairs_for_json, "head_part200", $nextBlock );

push( @pairs_for_json, "head_part300_VI", '$problemHeadText' . "\n" );

$nextBlock = <<'ENDPROBLEMTEMPLATE';
<title>WeBWorK problem</title>
ENDPROBLEMTEMPLATE

push( @pairs_for_json, "head_part400", $nextBlock );

push( @pairs_for_json, "head_part999", "</head>\n" );

push( @pairs_for_json, "body_part001", "<body>\n" );

$nextBlock = <<'ENDPROBLEMTEMPLATE';
<div class="container-fluid">
<div class="row-fluid">
<div class="span12 problem">
ENDPROBLEMTEMPLATE

push( @pairs_for_json, "body_part100", $nextBlock );

push( @pairs_for_json, "body_part300_VI", '$answerTemplate' . "\n" );

$nextBlock = <<'ENDPROBLEMTEMPLATE';
<form id="problemMainForm" class="problem-main-form" name="problemMainForm" action="TO_SET_LATER_FORM_ACTION_URL" method="post" onsubmit="submitAction()">
ENDPROBLEMTEMPLATE

push( @pairs_for_json, "body_part500", $nextBlock );


$nextBlock = <<'ENDPROBLEMTEMPLATE';
<div id="problem_body" class="problem-content" $PROBLEM_LANG_AND_DIR>
ENDPROBLEMTEMPLATE

push( @pairs_for_json, "body_part530_VI", $nextBlock );

push( @pairs_for_json, "body_part550_VI", '$problemText' . "\n" );

push( @pairs_for_json, "body_part590", "</div>\n" );

push( @pairs_for_json, "body_part650_VI", '$scoreSummary' . "\n" );

$nextBlock = <<'ENDPROBLEMTEMPLATE';
<p>
<input type="submit" name="preview"  value="$STRING_Preview" />
<input type="submit" name="WWsubmit" value="$STRING_Submit"/>
ENDPROBLEMTEMPLATE

push( @pairs_for_json, "body_part710_VI", $nextBlock );

$nextBlock = <<'ENDPROBLEMTEMPLATE';
<input type="submit" name="WWcorrectAns" value="$STRING_ShowCorrect"/>
ENDPROBLEMTEMPLATE

push( @pairs_for_json, "body_part780_optional_VI", $nextBlock );

push( @pairs_for_json, "body_part790", "</p>\n" );

$nextBlock = <<'ENDPROBLEMTEMPLATE';
</form>
</div>
</div>
</div>
<div id="footer" lang="en" dir="ltr">
WeBWorK &copy; 1996-2019
</div>
</body>
</html>
ENDPROBLEMTEMPLATE

push( @pairs_for_json, "body_part999", $nextBlock );

push( @pairs_for_json, "hidden_input_field_answersSubmitted", '1' );
push( @pairs_for_json, "hidden_input_field_sourceFilePath", '$sourceFilePath' );
push( @pairs_for_json, "hidden_input_field_problemSource", '$encoded_source' );
push( @pairs_for_json, "hidden_input_field_problemSeed", '$problemSeed' );
push( @pairs_for_json, "hidden_input_field_problemUUID", '$problemUUID' );
push( @pairs_for_json, "hidden_input_field_psvn", '$psvn' );
push( @pairs_for_json, "hidden_input_field_pathToProblemFile", '$fileName' );
push( @pairs_for_json, "hidden_input_field_courseName", '$courseID' );
push( @pairs_for_json, "hidden_input_field_courseID", '$courseID' );
push( @pairs_for_json, "hidden_input_field_userID", '$userID' );
push( @pairs_for_json, "hidden_input_field_course_password", '$course_password' );
push( @pairs_for_json, "hidden_input_field_displayMode", '$displayMode' );
push( @pairs_for_json, "hidden_input_field_session_key", '$session_key' );
push( @pairs_for_json, "hidden_input_field_outputFormat", 'json' );
push( @pairs_for_json, "hidden_input_field_language", '$formLanguage' );
push( @pairs_for_json, "hidden_input_field_showSummary", '$showSummary' );
push( @pairs_for_json, "hidden_input_field_forcePortNumber", '$forcePortNumber' );

# These are the real WeBWorK server URLs which the intermediate needs to use
# to communicate with WW, while the distant client must use URLs of the
# intermediate server (the man in the middle).

push( @pairs_for_json, "real_webwork_SITE_URL", '$SITE_URL' );
push( @pairs_for_json, "real_webwork_FORM_ACTION_URL", '$FORM_ACTION_URL' );
push( @pairs_for_json, "internal_problem_lang_and_dir", '$PROBLEM_LANG_AND_DIR');

# Output back to WebworkClient.pm is the reference to the array:
\@pairs_for_json;

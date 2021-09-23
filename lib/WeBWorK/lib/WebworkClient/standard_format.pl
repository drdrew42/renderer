$standard_format = <<'ENDPROBLEMTEMPLATE';
<html $COURSE_LANG_AND_DIR>
<head>
<meta charset='utf-8'>
<base href="$SITE_URL">
<link rel="shortcut icon" href="$webwork_htdocs_url/images/favicon.ico"/>

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

$extra_css_files

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

$extra_js_files

$problemHeadText
$problemPostHeaderText

<title>WeBWorK using host: $SITE_URL, format: standard seed: $problemSeed course: $courseID</title>
</head>
<body>

<h2> WeBWorK using host: $SITE_URL, course: $courseID format: standard</h2>
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
	       <input type="hidden" name="problemSeed" value="$problemSeed">
	       <input type="hidden" name="problemUUID" value="$problemUUID">
	       <input type="hidden" name="psvn" value="$psvn">
	       <input type="hidden" name="pathToProblemFile" value="$fileName">
	       <input type="hidden" name=courseName value="$courseID">
	       <input type="hidden" name=courseID value="$courseID">
	       <input type="hidden" name="userID" value="$userID">
	       <input type="hidden" name="course_password" value="$course_password">
	       <input type="hidden" name="displayMode" value="$displayMode">
	       <input type="hidden" name="session_key" value="$session_key">
	       <input type="hidden" name="outputFormat" value="standard">
	       <input type="hidden" name="language" value="$formLanguage">
	       <input type="hidden" name="showSummary" value="$showSummary">
	       <input type="hidden" name="forcePortNumber" value="$forcePortNumber">

		   <p>
       Show:&nbsp;&nbsp;
       <label for="showCorrectAnswers_id"><input id="showCorrectAnswers_id" name="showCorrectAnswers" type="checkbox" value="1" /> CorrectAnswers</label>&nbsp;
       <label for="showAnsGroupInfo_id"><input id="showAnsGroupInfo_id" name="showAnsGroupInfo" type="checkbox" value="1" /> AnswerGroupInfo</label>&nbsp;
       <label for="showResourceInfo_id"><input id="showResourceInfo_id" name="showResourceInfo" type="checkbox" value="1" /> Show Auxiliary Resources</label>&nbsp;
       <label for="showAnsHashInfo_id"><input id="showAnsHashInfo_id" name="showAnsHashInfo" type="checkbox" value="1" /> AnswerHashInfo</label>&nbsp;
       <label for="showPGInfo_id"><input id="showPGInfo_id" name="showPGInfo" type="checkbox" value="1" /> PGInfo</label>&nbsp;<br />

			<input type="submit" name="previewAnswers"  value="$STRING_Preview" />
			<input type="submit" name="submitAnswers" value="$STRING_Submit"/>
			<input type="submit" name="showCorrectAns" value="$STRING_ShowCorrect"/>
		   </p>
	</form>
<HR>

<h3> Perl warning section </h3>
$warnings
<h3> PG Warning section </h3>
$PG_warning_messages;
<h3> Debug message section </h3>
$debug_messages
<h3> internal errors </h3>
$internal_debug_messages
<div id="footer">
WeBWorK &copy; 1996-2019 | host: $SITE_URL | course: $courseID | format: standard | theme: math4
</div>

</body>
</html>

ENDPROBLEMTEMPLATE

$standard_format;

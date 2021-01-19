$standard_format = <<'ENDPROBLEMTEMPLATE';
<html $COURSE_LANG_AND_DIR>
<head>
<meta charset='utf-8'>
<base href="$SITE_URL">
<link rel="shortcut icon" href="/webwork2_files/images/favicon.ico"/>

<!-- CSS Loads -->
<link rel="stylesheet" type="text/css" href="/webwork2_files/css/jquery-ui.css"/>
<link rel="stylesheet" type="text/css" href="/webwork2_files/js/vendor/bootstrap/css/bootstrap.min.css"/>
<link rel="stylesheet" type="text/css" href="/webwork2_files/js/vendor/bootstrap/css/bootstrap-responsive.min.css"/>
<link rel="stylesheet" type="text/css" href="/webwork2_files/css/bootstrap.sub.css"/>
<link rel="stylesheet" type="text/css" href="/webwork2_files/themes/math4/math4.css"/>
<link rel="stylesheet" type="text/css" href="/webwork2_files/css/knowlstyle.css"/>
<link rel="stylesheet" type="text/css" href="/webwork2_files/js/apps/MathQuill/mathquill.css"/>
<link rel="stylesheet" type="text/css" href="/webwork2_files/js/apps/MathQuill/mqeditor.css"/>

<!-- JS Loads -->
<script>function submitAction() {}</script>
<script type="text/javascript" src="/webwork2_files/js/jquery.min.js"></script>
<script type="text/javascript" src="/webwork2_files/js/jquery-ui.min.js"></script>
<script type="text/javascript" async src="https://cdnjs.cloudflare.com/ajax/libs/mathjax/2.7.7/latest.js?config=TeX-MML-AM_CHTML"></script>
<script type="text/javascript" src="/webwork2_files/js/apps/AddOnLoad/addOnLoadEvent.js"></script>
<script type="text/javascript" src="/webwork2_files/js/legacy/java_init.js"></script>
<script type="text/javascript" src="/webwork2_files/js/apps/InputColor/color.js"></script>
<script type="text/javascript" src="/webwork2_files/js/apps/Base64/Base64.js"></script>
<script type="text/javascript" src="/webwork2_files/js/legacy/vendor/knowl.js"></script>
<script type="text/javascript" src="/webwork2_files/themes/math4/math4.js"></script>
<script type="text/javascript" src="/webwork2_files/js/vendor/iframe-resizer/js/iframeResizer.contentWindow.min.js"></script>
<script type="text/javascript" src="/webwork2_files/js/apps/MathQuill/mathquill.min.js"></script>
<script type="text/javascript" src="/webwork2_files/js/apps/MathQuill/mqeditor.js"></script>
<script type="text/javascript" src="/webwork2_files/js/submithelper.js"></script>

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
	       <input type="hidden" name="outputformat" value="standard">
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

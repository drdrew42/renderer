$simple_format = <<'ENDPROBLEMTEMPLATE';
<!DOCTYPE html>
<html $COURSE_LANG_AND_DIR>
<head>
<meta charset='utf-8'>
<base href="$SITE_URL">
<link rel="shortcut icon" href="$webwork_htdocs_url/images/favicon.ico"/>

<!-- CSS Loads -->
<link rel="stylesheet" type="text/css" href="$webwork_htdocs_url/css/jquery-ui.css"/>
<link rel="stylesheet" type="text/css" href="$webwork_htdocs_url/js/vendor/bootstrap/css/bootstrap.min.css"/>
<link rel="stylesheet" type="text/css" href="$webwork_htdocs_url/js/vendor/bootstrap/css/bootstrap-responsive.min.css"/>
<link rel="stylesheet" type="text/css" href="$webwork_htdocs_url/css/bootstrap.sub.css"/>
<link rel="stylesheet" type="text/css" href="$webwork_htdocs_url/themes/math4/math4.css"/>
<link rel="stylesheet" type="text/css" href="$webwork_htdocs_url/css/knowlstyle.css"/>
<link rel="stylesheet" type="text/css" href="$webwork_htdocs_url/js/apps/MathQuill/mathquill.css"/>
<link rel="stylesheet" type="text/css" href="$webwork_htdocs_url/js/apps/MathQuill/mqeditor.css"/>

<!-- JS Loads -->
<script>function submitAction() {}</script>
<script type="text/javascript" src="$webwork_htdocs_url/js/jquery.min.js"></script>
<script type="text/javascript" src="$webwork_htdocs_url/js/jquery-ui.min.js"></script>
<script type="text/javascript" async src="https://cdnjs.cloudflare.com/ajax/libs/mathjax/2.7.7/latest.js?config=TeX-MML-AM_CHTML"></script>
<script type="text/javascript" src="$webwork_htdocs_url/js/apps/AddOnLoad/addOnLoadEvent.js"></script>
<script type="text/javascript" src="$webwork_htdocs_url/js/legacy/java_init.js"></script>
<script type="text/javascript" src="$webwork_htdocs_url/js/apps/InputColor/color.js"></script>
<script type="text/javascript" src="$webwork_htdocs_url/js/apps/Base64/Base64.js"></script>
<script type="text/javascript" src="$webwork_htdocs_url/js/legacy/vendor/knowl.js"></script>
<script type="text/javascript" src="$webwork_htdocs_url/themes/math4/math4.js"></script>
<script type="text/javascript" src="$webwork_htdocs_url/js/vendor/iframe-resizer/js/iframeResizer.contentWindow.min.js"></script>
<script type="text/javascript" src="$webwork_htdocs_url/js/apps/MathQuill/mathquill.min.js"></script>
<script type="text/javascript" src="$webwork_htdocs_url/js/apps/MathQuill/mqeditor.js"></script>
<script type="text/javascript" src="$webwork_htdocs_url/js/submithelper.js"></script>

$problemHeadText
$problemPostHeaderText

<title>WeBWorK using host: $SITE_URL, format: simple seed: $problemSeed</title>
</head>
<body>
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
          <input type="hidden" name="problemSource" value="$encoded_source">
          <input type="hidden" name="problemSeed" value = "$problemSeed">
          <input type="hidden" name="language" value="$formLanguage">
          <input type="hidden" name="showSummary" value="$showSummary">
          <p>

            <input type="submit" name="previewAnswers"  value="$STRING_Preview" />
            <input type="submit" name="submitAnswers" value="$STRING_Submit"/>
          </p>
        </form>
      </div>
    </div>
  </div>
</body>
</html>

ENDPROBLEMTEMPLATE

$simple_format;

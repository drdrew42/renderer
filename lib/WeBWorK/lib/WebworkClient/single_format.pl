$single_format = <<'ENDPROBLEMTEMPLATE';
<!DOCTYPE html>
<html $COURSE_LANG_AND_DIR>
<head>
<meta charset='utf-8'>
<base href="$SITE_URL">
<link rel="shortcut icon" href="/webwork2_files/images/favicon.ico"/>

<!-- CSS Loads -->
<link rel="stylesheet" type="text/css" href="/webwork2_files/js/vendor/bootstrap/css/bootstrap.css"/>
<link rel="stylesheet" type="text/css" href="/webwork2_files/js/vendor/bootstrap/css/bootstrap-responsive.css"/>
<link rel="stylesheet" type="text/css" href="/webwork2_files/css/jquery-ui-1.8.18.custom.css"/>
<link rel="stylesheet" type="text/css" href="/webwork2_files/css/vendor/font-awesome/css/font-awesome.min.css"/>
<link rel="stylesheet" type="text/css" href="/webwork2_files/themes/math4/math4.css"/>
<link rel="stylesheet" type="text/css" href="/webwork2_files/css/knowlstyle.css"/>
<link rel="stylesheet" type="text/css" href="/webwork2_files/js/apps/MathQuill/mathquill.css"/>
<link rel="stylesheet" type="text/css" href="/webwork2_files/js/apps/MathQuill/mqeditor.css"/>

<!-- JS Loads -->
<script type="text/javascript" src="/webwork2_files/js/vendor/jquery/jquery.js"></script>
<script type="text/javascript" src="/webwork2_files/mathjax/MathJax.js?config=TeX-MML-AM_HTMLorMML-full"></script>
<script type="text/javascript" src="/webwork2_files/js/jquery-ui-1.9.0.js"></script>
<script type="text/javascript" src="/webwork2_files/js/vendor/bootstrap/js/bootstrap.js"></script>
<script type="text/javascript" src="/webwork2_files/js/apps/AddOnLoad/addOnLoadEvent.js"></script>
<script type="text/javascript" src="/webwork2_files/js/legacy/java_init.js"></script>
<script type="text/javascript" src="/webwork2_files/js/apps/InputColor/color.js"></script>
<script type="text/javascript" src="/webwork2_files/js/apps/Base64/Base64.js"></script>
<script type="text/javascript" src="/webwork2_files/js/vendor/underscore/underscore.js"></script>
<script type="text/javascript" src="/webwork2_files/js/legacy/vendor/knowl.js"></script>
<script type="text/javascript" src="/webwork2_files/js/apps/Problem/problem.js"></script>
<script type="text/javascript" src="/webwork2_files/themes/math4/math4.js"></script>
<script type="text/javascript" src="/webwork2_files/js/vendor/iframe-resizer/js/iframeResizer.contentWindow.min.js"></script>
<script type="text/javascript" src="/webwork2_files/js/apps/MathQuill/mathquill.min.js"></script>
<script type="text/javascript" src="/webwork2_files/js/apps/MathQuill/mqeditor.js"></script>
<script type="text/javascript" src="/iframeResizer.contentWindow.min.js"></script>

$problemHeadText

<title>Rederly Standalone Renderer</title>
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
          <input type="hidden" name="outputformat" value="single">
          <input type="hidden" name="language" value="$formLanguage">
          <input type="hidden" name="showSummary" value="$showSummary">
          <p>

            <input type="submit" name="submitAnswers" value="$STRING_Submit"/>
          </p>
        </form>
      </div>
    </div>
  </div>
</body>
</html>

ENDPROBLEMTEMPLATE

$single_format;

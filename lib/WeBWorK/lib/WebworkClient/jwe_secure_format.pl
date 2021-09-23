$jwe_format = <<'ENDPROBLEMTEMPLATE';
<!DOCTYPE html>
<html $COURSE_LANG_AND_DIR>
<head>
<meta charset='utf-8'>
<base href="$SITE_URL">
<link rel="shortcut icon" href="$webwork_htdocs_url/images/favicon.ico"/>

<!-- CSS Loads -->
<link rel="stylesheet" href="$webwork_htdocs_url/node_modules/jquery-ui-dist/jquery-ui.min.css" />
<link rel="stylesheet" href="$webwork_htdocs_url/node_modules/@fortawesome/fontawesome-free/css/all.min.css" />
<link rel="stylesheet" href="$webwork_htdocs_url/node_modules/bootstrap/dist/css/bootstrap.min.css"/>
<link rel="stylesheet" href="$webwork_htdocs_url/js/apps/Problem/problem.css"/>
<link rel="stylesheet" href="$webwork_htdocs_url/js/apps/Knowls/knowl.css"/>

<link rel="stylesheet" href="$webwork_htdocs_url/js/apps/MathQuill/mathquill.css"/>
<link rel="stylesheet" href="$webwork_htdocs_url/js/apps/MathQuill/mqeditor.css"/>
<link rel="stylesheet" href="$webwork_htdocs_url/js/apps/ImageView/imageview.css"/>

$extra_css_files

<!-- JS Loads -->
<script src="$webwork_htdocs_url/js/apps/MathJaxConfig/mathjax-config.js" defer></script>
<script src="$webwork_htdocs_url/mathjax/es5/tex-chtml.js" id="MathJax-script" defer></script>
<script src="$webwork_htdocs_url/node_modules/bootstrap/dist/js/bootstrap.bundle.min.js"></script>
<script src="$webwork_htdocs_url/node_modules/jquery/dist/jquery.min.js"></script>
<script src="$webwork_htdocs_url/node_modules/jquery-ui-dist/jquery-ui.min.js"></script>
<script src="$webwork_htdocs_url/js/apps/Problem/problem.js" defer></script>
<script src="$webwork_htdocs_url/js/apps/InputColor/color.js"></script>
<script src="$webwork_htdocs_url/js/apps/Knowls/knowl.js" defer></script>
<script src="$webwork_htdocs_url/js/apps/ImageView/imageview.js"></script>
<script src="$webwork_htdocs_url/node_modules/iframe-resizer/js/iframeResizer.contentWindow.min.js"></script>

<script src="$webwork_htdocs_url/js/apps/MathQuill/mathquill.min.js" defer></script>
<script src="$webwork_htdocs_url/js/apps/MathQuill/mqeditor.js" defer></script>
<script src="$webwork_htdocs_url/js/submithelper.js"></script>

$extra_js_files

$problemHeadText
$problemPostHeaderText

<title>WeBWorK using host: $SITE_URL</title>
</head>
<body>
  <div class="container-fluid">
    <div class="row">
      <div class="col-12 problem">
        $answerTemplate
        $color_input_blanks_script
        <form id="problemMainForm" class="problem-main-form" name="problemMainForm" action="$FORM_ACTION_URL" method="post">
          <div id="problem_body" class="problem-content" $PROBLEM_LANG_AND_DIR>
            $problemText
          </div>
          $scoreSummary
          $LTIGradeMessage
          <input type="hidden" name="sessionJWT" value="$sessionJWT">
          <input type="hidden" name="problemJWT" value="$problemJWT">
          <p>
            <input type="submit" name="previewAnswers" class="btn btn-primary" value="$STRING_Preview" />
            <input type="submit" name="submitAnswers" class="btn btn-primary" value="$STRING_Submit"/>
          </p>
        </form>
      </div>
    </div>
  </div>
  <script>
    if ('JWTanswerURLstatus') {
      console.log("response message ", JSON.parse('JWTanswerURLstatus'));
      window.parent.postMessage('JWTanswerURLstatus', '*');
    }
  </script>
</body>
</html>

ENDPROBLEMTEMPLATE

$jwe_format;

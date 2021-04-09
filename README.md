# WeBWorK Standalone Problem Renderer & Editor

![Commit Activity](https://img.shields.io/github/commit-activity/m/drdrew42/renderer?style=plastic)
![License](https://img.shields.io/github/license/drdrew42/renderer?style=plastic)


This is a PG Renderer derived from the WeBWorK2 codebase
* https://github.com/openwebwork/WeBWorK2

## DOCKER CONTAINER INSTALL ###

```
mkdir volumes
mkdir container
git clone https://github.com/openwebwork/webwork-open-problem-library volumes/webwork-open-problem-library
git clone --recursive https://github.com/drdrew42/renderer container/
docker build --tag renderer:1.0 ./container

docker run -d \
  --publish 3000:3000 \
  --mount type=bind,source="$(pwd)"/volumes/webwork-open-problem-library/,target=/usr/app/webwork-open-problem-library \
  renderer:1.0
```

If you have non-OPL content, it should be mounted as a volume at `/usr/app/private`.

```
docker run -d \
  --publish 3000:3000 \
  --mount type=bind,source="$(pwd)"/volumes/webwork-open-problem-library/,target=/usr/app/webwork-open-problem-library \
  --mount type=bind,source=/pathToYourLocalContentRoot,target=/usr/app/private \
  renderer:1.0
```

## LOCAL INSTALL ###

If using a local install instead of docker:

* Dockerfile lists perl dependencies
* clone PG and webwork-open-problem-library into the provided stubs ./lib/PG and ./webwork-open-problem-library
  - `git clone https://github.com/openwebwork/pg ./lib/PG`
  - `git clone https://github.com/openwebwork/webwork-open-problem-library ./webwork-open-problem-library`
* copy `render_app.conf.dist` to `render_app.conf`
* start the app with `morbo ./script/render_app` or `morbo -l http://localhost:3000 ./script/render_app` if changing root url
* access on `localhost:3000` by default or otherwise specified root url

# Editor Interface

Point your browser at `localhost:3000`, select an output format, a problem path and a problem seed. Click on "Load" to load the problem source into the editor, and from there you can render the contents of the editor (with or without edits). Clicking on "Save" will save your edits to the specified file path.

# Renderer API
Can be interfaced through `/render-api`

## Parameters
| Key | Type | Default Value | Required | Description | Notes |
| --- | ---- | ------------- | -------- | ----------- | ----- |
| sourceFilePath | string | null | true if problemSource is null | The path to the file to be rendered | Can begin with Library or Contrib, in which case the renderer will automatically adjust the path from the webwork-open-problem-library root |
| problemSource | string | null | true if sourceFilePath is null | The source of a problem to render | base64 encoded raw pg content - can be used instead of sourceFilePath |
| problemSeed | number | NA | true | The seed to determine the randomization of a problem | |
| psvn | number | 123 | false | used for consistent randomization between problems | |
| formURL | string | /render-api | false | the URL for form submission | |
| baseURL | string | / | false | the URL for relative paths | |
| outputFormat | string (enum) | static | false | Determines how the problem should render, see below descriptions below | |
| language | string | en | false | Language to render the problem in (if supported) | |
| showHints | number (boolean) | 1 | false | Whether or not to show hints (restrictions apply) | Hint logic only applies so long as showHints is 'true' (1), if false (0) hints will not be shown, no exceptions)
| showSolutions | number (boolean) | 0 | false | Whether or not to show the solutions | |
| permissionLevel | number | 0 | false | Aids in the conrol of show hints, also controls display of scaffold problems (possibly more) | See the levels we use below |
| problemNumber | number | 1 | false | We don't use this | |
| numCorrect | number | 0 | false | The number of correct attempts on a problem | |
| numIncorrect | number | 1000 | false | the number of incorrect attempts on this problem | Relevant for triggering hints that are not immediately available |
| processAnswers | number (boolean) | 1 | false | Determines whether or not answer json is populated, and whether or not problem_result and problem_state are non-empty | |
| answersSubmitted | number (boolean) | ? | false? | Determines whether to process form-data associated to the available input fields | |
| showSummary | number (boolean) | ? | false? | Determines whether or not to show the summary result of processing the form-data associated with `answersSubmitted` above ||

## Output Format
| Key | Description |
| ----- | ----- |
| static | zero buttons, locked form fields (read-only) |
| nosubmit | zero buttons, editable (for exams, save problem state and submit all together) |
| single | one submit button (intended for graded content) |
| classic | preview + submit buttons |
| simple | preview + submit + show answers buttons |
| practice | check answers + show answers buttons |

## Permission level
| Key | Value |
| --- | ----- |
| student | 0 |
| prof | 10 |
| admin | 20 |

## Permission logic summary for hints and solutions
* If showHints (or showSolutions) is false, no hint (or solution) will be rendered - no exceptions.
* If showSolutions is true, then solutions will be rendered (presuming they are provided in the pg source code)
* If showHints is true (and the pg source code provides hints), then hints will render
    - if `permissionLevel >= 10`, or
    - if `numCorrect + numIncorrect > n`, where `n` is set by the pg source code being rendered
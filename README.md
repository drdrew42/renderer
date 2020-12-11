# Rederly Standalone Problem Renderer & Editor

![Commit Activity](https://img.shields.io/github/commit-activity/m/rederly/renderer?style=plastic)
![License](https://img.shields.io/github/license/rederly/renderer?style=plastic)


This is a PG Renderer derived from the WeBWorK2 codebase
* https://github.com/openwebwork/WeBWorK2

## DOCKER CONTAINER INSTALL ###

```
mkdir volumes
mkdir container
git clone https://github.com/openwebwork/webwork-open-problem-library volumes/webwork-open-problem-library
git clone --recursive https://github.com/rederly/renderer container/
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
| showHints | number (boolean) | 1 | false | Whether or not to show hints (restrictions apply) | Hint logic has some hooks into the problem source, if permission level is high enough or `n` number of attempts has been reached they will render if this is true (1), however if false (0) you will never see the hints)
| showSolutions | number (boolean) | 0 | false | Whether or not to show the solutions | |
| permissionLevel | number | 0 | false | Aids in the conrol of show hints, also controls display of scaffold problems (possibly more) | See the levels we use below |
| problemNumber | number | 1 | false | We don't use this | |
| numCorrect | number | 0 | false | The number of correct attempts on a problem | |
| numIncorrect | number | 1000 | false | the number of incorrect attempts on this problem | Relevant for triggering hints that are not immediately available |
| processAnswers | number (boolean) | 1 | false | Determines whether or not answer json is populated, and whether or not problem_result and problem_state are non-empty | |

## Output Format
| Key | Description |
| ----- | ----- |
| static | zero buttons, locked form fields (read-only) |
| nosubmit | zero buttons, editable (for exams, save problem state and submit all together) |
| single | one submit button (intended for graded content) |
| simple | submit button + show answers button |

## Permission level
| Key | Value |
| --- | ----- |
| student | 0 |
| prof | 10 |
| admin | 20 |

## Permission logic summary for hints and solutions
* If professor or above (permission value >= 10) you will always get hints and solutions
* If student you will get solutions if and only if we set the showSolutions flag to true
* If student you will get hints after you have exceeded the attempt threshold (if the flag is set to true)
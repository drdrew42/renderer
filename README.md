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
  --rm \
  --name standalone-renderer \
  --publish 3000:3000 \
  --mount type=bind,source="$(pwd)"/volumes/webwork-open-problem-library/,target=/usr/app/webwork-open-problem-library \
  renderer:1.0
```

If you have non-OPL content, it can be mounted as a volume at `/usr/app/private` by adding the following line to the `docker run` command:

```
  --mount type=bind,source=/pathToYourLocalContentRoot,target=/usr/app/private \
```

A default configuration file is included in the container, but it can be overridden by mounting a replacement at the application root.

```
  --mount type=bind,source=/pathToYour/configuration_file.conf,target=/usr/app/render_app.conf \
```

## LOCAL INSTALL ###

If using a local install instead of docker:

* Clone the renderer and its submodules: `git clone --recursive https://github.com/drdrew42/renderer`
* Enter the project directory: `cd renderer`
* Install perl dependencies listed in Dockerfile (CPANMinus recommended)
* clone webwork-open-problem-library into the provided stub ./webwork-open-problem-library
  - `git clone https://github.com/openwebwork/webwork-open-problem-library ./webwork-open-problem-library`
* copy `render_app.conf.dist` to `render_app.conf` and make any desired modifications
* install other dependencies
  - `cd lib/WeBWorK/htdocs`
  - `npm install`
* start the app with `morbo ./script/render_app` or `morbo -l http://localhost:3000 ./script/render_app` if changing root url
* access on `localhost:3000` by default or otherwise specified root url

# Editor Interface

* point your browser at [`localhost:3000`](http://localhost:3000/)
* select an output format (see below)
* specify a problem path (e.g. `Library/Rochester/setMAAtutorial/hello.pg`) and a problem seed (e.g. `1234`)
* click on "Load" to load the problem source into the editor
* render the contents of the editor (with or without edits) via "Render contents of editor"
* click on "Save" to save your edits to the specified file path

![image](https://user-images.githubusercontent.com/3385756/129100124-72270558-376d-4265-afe2-73b5c9a829af.png)

# Renderer API
Can be interfaced through `/render-api`

## Parameters
| Key | Type | Default Value | Required | Description | Notes |
| --- | ---- | ------------- | -------- | ----------- | ----- |
| problemSourceURL | string | null | true if `sourceFilePath` and `problemSource` are null | The URL from which to fetch the problem source code | Takes precedence over `problemSource` and `sourceFilePath`. A request to this URL is expected to return valid pg source code in base64 encoding. |
| problemSource | string (base64 encoded) | null | true if `problemSourceURL` and `sourceFilePath` are null | The source code of a problem to be rendered | Takes precedence over `sourceFilePath`. |
| sourceFilePath | string | null | true if `problemSource` and `problemSourceURL` are null | The path to the file that contains the problem source code | Can begin with Library/ or Contrib/, in which case the renderer will automatically adjust the path relative to the webwork-open-problem-library root. Path may also begin with `private/` for local, non-OPL content. |
| problemSeed | number | NA | true | The seed to determine the randomization of a problem | |
| psvn | number | 123 | false | used for consistent randomization between problems | |
| formURL | string | /render-api | false | the URL for form submission | |
| baseURL | string | / | false | the URL for relative paths | |
| format | string | '' | false | Determine how the response is formatted ('html' or 'json') ||
| outputFormat | string (enum) | static | false | Determines how the problem should render, see below descriptions below | |
| language | string | en | false | Language to render the problem in (if supported) | |
| showHints | number (boolean) | 1 | false | Whether or not to show hints (restrictions apply) | Irrelevant if `permissionLevel >= 10`, in which case `showHints` is regarded as automatically 'true' |
| showSolutions | number (boolean) | 0 | false | Whether or not to show the solutions (restrictions apply) | Irrelevant if `permissionLevel >= 10`, in which case `showSolutions` is regarded as automatically 'true' |
| permissionLevel | number | 0 | false | Affects the rendering of hints and solutions. Also controls display of scaffold problems (possibly more) | See the levels we use below |
| problemNumber | number | 1 | false | We don't use this | |
| numCorrect | number | 0 | false | The number of correct attempts on a problem | |
| numIncorrect | number | 1000 | false | the number of incorrect attempts on this problem | Relevant for triggering hints that are not immediately available |
| processAnswers | number (boolean) | 1 | false | Determines whether or not answer json is populated, and whether or not problem_result and problem_state are non-empty | |
| answersSubmitted | number (boolean) | ? | false? | Determines whether to process form-data associated to the available input fields | |
| showSummary | number (boolean) | ? | false? | Determines whether or not to show the summary result of processing the form-data associated with `answersSubmitted` above ||
| showComments | number (boolean) | 0 | false | Renders author comment field at the end of the problem ||
| includeTags | number (boolean) | 0 | false | Includes problem tags in the returned JSON | Only relevant when requesting `format: 'json'` |

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
* If `permissionLevel >= 10`, then hints and solutions will be rendered - no exceptions.
* If `permissionLevel < 10`, then:
    - solutions (if they are provided in the pg source code) will be rendered if and only if `showSolutions` is true.
    - hints (if they are provided in the pg source code) will be rendered if and only if:
        + `showHints` is true, and
        + `numCorrect + numIncorrect > n` where `n` is set by the pg sourcce code being rendered

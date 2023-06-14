# WeBWorK Standalone Problem Renderer & Editor

![Commit Activity](https://img.shields.io/github/commit-activity/m/openwebwork/renderer?style=plastic)
![License](https://img.shields.io/github/license/openwebwork/renderer?style=plastic)

This is a PG Renderer derived from the WeBWorK2 codebase

* [https://github.com/openwebwork/webwork2](https://github.com/openwebwork/webwork2)

## DOCKER CONTAINER INSTALL

```bash
mkdir volumes
mkdir container
git clone https://github.com/openwebwork/webwork-open-problem-library volumes/webwork-open-problem-library
git clone --recursive https://github.com/openwebwork/renderer container/
docker build --tag renderer:1.0 ./container

docker run -d \
  --rm \
  --name standalone-renderer \
  --publish 3000:3000 \
  --mount type=bind,source="$(pwd)"/volumes/webwork-open-problem-library/,target=/usr/app/webwork-open-problem-library \
  --env MOJO_MODE=development \
  renderer:1.0
```

If you have non-OPL content, it can be mounted as a volume at `/usr/app/private` by adding the following line to the
`docker run` command:

```bash
  --mount type=bind,source=/pathToYourLocalContentRoot,target=/usr/app/private \
```

A default configuration file is included in the container, but it can be overridden by mounting a replacement at the
  application root. This is necessary if, for example, you want to run the container in `production` mode.

```bash
  --mount type=bind,source=/pathToYour/render_app.conf,target=/usr/app/render_app.conf \
```

## LOCAL INSTALL

If using a local install instead of docker:

* Clone the renderer and its submodules: `git clone --recursive https://github.com/openwebwork/renderer`
* Enter the project directory: `cd renderer`
* Install Perl dependencies listed in Dockerfile (CPANMinus recommended)
* clone webwork-open-problem-library into the provided stub ./webwork-open-problem-library
  * `git clone https://github.com/openwebwork/webwork-open-problem-library ./webwork-open-problem-library`
* copy `render_app.conf.dist` to `render_app.conf` and make any desired modifications
* copy `conf/pg_config.yml` to `lib/PG/pg_config.yml` and make any desired modifications
* install third party JavaScript dependencies
  * `cd private/`
  * `npm install`
  * `cd ..`
* install PG JavaScript dependencies
  * `cd lib/PG/htdocs`
  * `npm install`
* start the app with `morbo ./script/render_app` or `morbo -l http://localhost:3000 ./script/render_app` if changing
  root url
* access on `localhost:3000` by default or otherwise specified root url

## Editor Interface

* point your browser at [`localhost:3000`](http://localhost:3000/)
* select an output format (see below)
* specify a problem path (e.g. `Library/Rochester/setMAAtutorial/hello.pg`) and a problem seed (e.g. `1234`)
* click on "Load" to load the problem source into the editor
* render the contents of the editor (with or without edits) via "Render contents of editor"
* click on "Save" to save your edits to the specified file path

![image](https://user-images.githubusercontent.com/3385756/129100124-72270558-376d-4265-afe2-73b5c9a829af.png)

## Server Configuration

Modification of `baseURL` may be necessary to separate multiple services running on `SITE_HOST`, and will be used to extend `SITE_HOST`. The result of this extension will serve as the root URL for accessing the renderer (and any supplementary assets it may need to provide in support of a rendered problem). If `baseURL` is an absolute URL, it will be used verbatim -- userful if the renderer is running behind a load balancer.

By default, `formURL` will further extend `baseURL`, and serve as the form-data target for user interactions with problems rendered by this service. If `formURL` is an absolute URL, it will be used verbatim -- useful if your implementation intends to sit in between the user and the renderer. 

## Renderer API

Can be accessed by POST to `{SITE_HOST}{baseURL}{formURL}`. 

By default, `localhost:3000/render-api`.

### **REQUIRED PARAMETERS**

The bare minimum of parameters that must be included are:
* the code for the problem, so, **ONE** of the following (in order of precedence):
  * `problemSource` (raw pg source code, _can_ be base64 encoded)
  * `sourceFilePath` (relative to OPL `Library/`, `Contrib/`; or in `private/`)
  * `problemSourceURL` (fetch the pg source from remote server)
* a "seed" value for consistent randomization
  * `problemSeed` (integer)

| Key | Type | Description | Notes |
| --- | ---- | ----------- | ----- |
| problemSource | string (possibly base64 encoded) | The source code of a problem to be rendered | Takes precedence over `sourceFilePath`. |
| sourceFilePath | string | The path to the file that contains the problem source code | Renderer will automatically adjust `Library/` and `Contrib/` relative to the webwork-open-problem-library root. Path may also begin with `private/` for local, non-OPL content. |
| problemSourceURL | string | The URL from which to fetch the problem source code | Takes precedence over `problemSource` and `sourceFilePath`. A request to this URL is expected to return valid pg source code in base64 encoding. |
| problemSeed | number | The seed that determines the randomization of a problem | |

**ALL** other request parameters are optional.

### Infrastructure Parameters

The defaults for these parameters are set in `render_app.conf`, but these can be overridden on a per-request basis.

| Key | Type | Default Value | Description | Notes |
| --- | ---- | ------------- | ----------- | ----- |
| baseURL | string | '/' (as set in `render_app.conf`) | the URL for relative paths | |
| formURL | string | '/render-api' (as set in `render_app.conf`) | the URL for form submission | |

### Display Parameters

#### Formatting

Parameters that control the structure and templating of the response.

| Key | Type | Default Value | Description | Notes |
| --- | ---- | ------------- | ----------- | ----- |
| language | string | en | Language to render the problem in (if supported) | affects the translation of template strings, _not_ actual problem content |
| _format | string | 'html' | Determine how the response is _structured_ ('html' or 'json') | usually 'html' if the user is directly interacting with the renderer, 'json' if your CMS sits between user and renderer |
| outputFormat | string | 'default' | Determines how the problem should be formatted | 'default', 'static', 'PTX', 'raw', or  |
| displayMode | string | 'MathJax' | How to prepare math content for display | 'MathJax' or 'ptx' |

#### User Interactions

Control how the user is allowed to interact with the rendered problem.

Requesting `outputFormat: 'static'` will prevent any buttons from being included in the rendered output, regardless of the following options.

| Key | Type | Default Value | Description | Notes |
| --- | ---- | ------------- | ----------- | ----- |
| hidePreviewButton | number (boolean) | false | "Preview My Answers" is enabled by default | |
| hideCheckAnswersButton | number (boolean) | false | "Submit Answers" is enabled by default | |
| showCorrectAnswersButton | number (boolean) | `isInstructor` | "Show Correct Answers" is disabled by default, enabled if `isInstructor` is true (see below) | |

#### Content

Control what is shown to the user: hints, solutions, attempt results, scores, etc.

| Key | Type | Default Value | Description | Notes |
| --- | ---- | ------------- | ----------- | ----- |
| permissionLevel | number | 0 | **DEPRECATED.** Use `isInstructor` instead. |
| isInstructor | number (boolean) | 0 | Is the user viewing the problem an instructor or not. | Used by PG to determine if scaffolds can be allowed to be open among other things |
| showHints | number (boolean) | 1 | Whether or not to show hints | |
| showSolutions | number (boolean) | `isInstructor` | Whether or not to show the solutions | |
| hideAttemptsTable | number (boolean) | 0 | Hide the table of answer previews/results/messages | If you have a replacement for flagging the submitted entries as correct/incorrect |
| showSummary | number (boolean) | 1 | Determines whether or not to show a summary of the attempt underneath the table | Only relevant if the Attempts Table is shown `hideAttemptsTable: false` (default) |
| showComments | number (boolean) | 0 | Renders author comment field at the end of the problem | |
| showFooter | number (boolean) | 0 | Show version information and WeBWorK copyright footer | |
| includeTags | number (boolean) | 0 | Includes problem tags in the returned JSON | Only relevant when requesting `_format: 'json'` |

## Using JWTs

There are three JWT structures that the Renderer uses, each containing its predecessor:
* problemJWT
* sessionJWT
* answerJWT

### ProblemJWT

This JWT encapsulates the request parameters described above, under the API heading. Any value set in the JWT cannot be overridden by form-data. For example, if the problemJWT includes `isInstructor: 0`, then any subsequent interaction with the problem rendered by this JWT cannot override this setting by including `isInstructor: 1` in the form-data. 

### SessionJWT

This JWT encapsulates a user's attempt on a problem, including:
* the text and LaTeX versions of each answer entry
* count of incorrect attempts (stopping after a correct attempt, or after `showCorrectAnswers` is used)
* the problemJWT

If stored (see next), this JWT can be submitted as the sole request parameter, and the response will effectively restore the users current state of interaction with the problem (as of their last submission). 

### AnswerJWT

If the initial problemJWT contains a value for `JWTanswerURL`, this JWT will be generated and sent to the specified URL. The answerJWT is the only content provided to the URL. The renderer is intended to to be user-agnostic. It is recommended that the JWTanswerURL specify the unique identifier for the user/problem combination. (e.g. `JWTanswerURL: 'https://db.yoursite.org/grades-api/:user_problem_id'`)

For security purposes, this parameter is only accepted when included as part of a JWT.

This JWT encapsulates the status of the user's interaction with the problem.
* score
* sessionJWT

The goal here is to update the `JWTanswerURL` with the score and "state" for the user. If you have uses for additional information, please feel free to suggest as a GitHub Issue. 

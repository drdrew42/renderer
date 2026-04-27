# WeBWorK Standalone Problem Renderer & Editor

![Commit Activity](https://img.shields.io/github/commit-activity/m/openwebwork/renderer?style=plastic)
![License](https://img.shields.io/github/license/openwebwork/renderer?style=plastic)

This is a PG Renderer derived from the WeBWorK2 codebase

- [https://github.com/openwebwork/webwork2](https://github.com/openwebwork/webwork2)

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
  --mount type=bind,source=/pathToYour/renderer.conf,target=/usr/app/renderer.conf \
```

## LOCAL INSTALL

If using a local install instead of docker:

- Clone the renderer and its submodules: `git clone --recursive https://github.com/openwebwork/renderer`
- Enter the project directory: `cd renderer`
- Install Perl dependencies listed in Dockerfile (CPANMinus recommended)
- clone webwork-open-problem-library into the provided stub ./webwork-open-problem-library
  - `git clone https://github.com/openwebwork/webwork-open-problem-library ./webwork-open-problem-library`
- copy `renderer.conf.dist` to `renderer.conf` and make any desired modifications
- copy `conf/pg_config.yml` to `lib/PG/pg_config.yml` and make any desired modifications
- install third party JavaScript dependencies
  - `cd public/`
  - `npm ci`
  - `cd ..`
- install PG JavaScript dependencies
  - `cd lib/PG/htdocs`
  - `npm ci`
- start the app with `morbo ./script/renderer` or `morbo -l http://localhost:3000 ./script/renderer` if changing
  root url
- access on `localhost:3000` by default or otherwise specified root url

## Editor Interface

- point your browser at [`localhost:3000`](http://localhost:3000/)
- select an output format (see below)
- specify a problem path (e.g. `Library/Rochester/setMAAtutorial/hello.pg`) and a problem seed (e.g. `1234`)
- click on "Load" to load the problem source into the editor
- render the contents of the editor (with or without edits) via "Render contents of editor"
- click on "Save" to save your edits to the specified file path

![image](https://user-images.githubusercontent.com/3385756/129100124-72270558-376d-4265-afe2-73b5c9a829af.png)

## Server Configuration

Configuration lives in `renderer.conf` (copied from `renderer.conf.dist` during build). All key settings can also be overridden via environment variables, which take precedence over the config file — this is the recommended approach for Docker deployments.

### Configuration Reference

| Setting | Env Override | Description |
|---------|-------------|-------------|
| `SITE_HOST` | `SITE_HOST` | Public-facing origin URL. Used as `<base href>` in rendered HTML and as issuer/audience in JWTs. Must match what the end user's browser sees. |
| `baseURL` | `baseURL` | Path prefix when mounted at a subpath (e.g. `renderer` for `https://example.com/renderer/`). If set to an absolute URL, overrides `SITE_HOST` for asset references. Leave empty when hosting at root. |
| `formURL` | `formURL` | Where answer forms POST to. Defaults to `{SITE_HOST}{baseURL}/render-api`. Set to an absolute URL for MITM deployments. |
| `problemJWTsecret` | `problemJWTsecret` | Shared secret for encrypting render configuration JWTs. Must match any service that creates problem tokens. |
| `webworkJWTsecret` | `webworkJWTsecret` | Shared secret for session state JWTs (attempt history, scores). |
| `CORS_ORIGIN` | — | Allowed origin for CORS headers. Set to the embedding site's origin for iframe deployments. `*` is insecure. |
| `STRICT_JWT` | `STRICT_JWT` | Entry gate. When `1`, ungrounded requests are rejected with 401 — the instance only serves callers arriving with a `problemJWT`, `challengeJWT`, `sessionJWT`, or `X-Peer-Signature`. When `0` (default), ungrounded requests are admitted. Orthogonal to answerJWT emission, which is always gated by upstream-JWT presence. |
| `SELF_MINT_DISABLED` | `SELF_MINT_DISABLED` | When unset (default), an admitted ungrounded request is wrapped in a self-minted `problemJWT` so the next render can flow through the standard `sessionJWT` round-trip without the consumer re-mailing `isInstructor`, `sessionID`, etc. Set to `1` for raw-passthrough deployments. Self-minted JWTs cannot ground answerJWT emission. |
| `FULL_APP_INSECURE` | — | Enables editor UI, OPL browser, and file management routes in production mode. Always available in development mode. |
| `STATIC_EXPIRES` | — | `Cache-Control` max-age (seconds) for static assets under `/webwork2_files/`. |

### Deployment Topologies

The renderer was designed to support several integration patterns. The URL configuration (`SITE_HOST`, `baseURL`, `formURL`) and JWT architecture adapt to each.

#### Standalone

The renderer serves problems directly to the user's browser. Simplest setup.

```
  Browser  ←→  Renderer
```

```bash
docker run -d -p 3000:3000 \
  -e SITE_HOST=https://renderer.example.com \
  renderer
```

`SITE_HOST` is the renderer's own public URL. `baseURL` and `formURL` are empty (defaults). The browser loads rendered HTML and submits answers directly to the renderer.

#### MITM Proxy

A middleware sits between the student and the renderer. The student's browser talks to the proxy, which forwards render requests and intercepts answer submissions.

```
  Browser  ←→  Proxy  ←→  Renderer
```

```bash
docker run -d -p 3000:3000 \
  -e SITE_HOST=http://localhost:3000 \
  -e baseURL=https://proxy.example.com/webwork/ \
  -e formURL=https://proxy.example.com/webwork/render-api \
  renderer
```

- `baseURL` is absolute (the proxy's origin) — rendered HTML references assets through the proxy
- `formURL` is absolute — answer forms POST to the proxy, not the renderer directly
- The proxy forwards render requests to the renderer's internal address and relays responses

#### Triangular / Iframe (e.g. LibreTexts)

The LMS and renderer are separate services. The student's browser communicates with both: the LMS issues a JWT, the browser loads the renderer in an iframe using that JWT, and the renderer reports scores back to the LMS asynchronously.

```
        LMS (LibreTexts)
       ↗ (1. get JWT)  ↖ (3. answerJWT callback)
  Browser  ——————————→  Renderer (iframe)
           (2. render + submit via JWT)
```

1. Student requests a problem from the LMS
2. LMS issues a `problemJWT` containing the render config and a `JWTanswerURL` pointing back at the LMS grading endpoint
3. Student's browser loads the renderer in an iframe, passing the `problemJWT`
4. On answer submission, the renderer POSTs an `answerJWT` (containing score + sessionJWT) to the `JWTanswerURL` from inside the token
5. LMS updates its gradebook; student can resume via `sessionJWT` if the iframe closes

```bash
docker run -d -p 3000:3000 \
  -e SITE_HOST=https://renderer.example.com \
  -e CORS_ORIGIN=https://lms.example.com \
  -e problemJWTsecret=<shared-with-LMS> \
  -e webworkJWTsecret=<renderer-internal> \
  renderer
```

- `SITE_HOST` must match the iframe's `src` origin (what the browser sees)
- `CORS_ORIGIN` is the LMS origin (the iframe's parent)
- `problemJWTsecret` must be shared between the LMS and renderer
- `JWTanswerURL` is embedded in the JWT by the LMS, not configured on the renderer
- Student submit paths that produce an answerJWT require a valid `problemJWT` (enforced automatically — no flag needed). Preview and browsing paths stay open.

## Renderer API

Can be accessed by POST to `{SITE_HOST}{baseURL}{formURL}`.

By default, `localhost:3000/render-api`.

### **REQUIRED PARAMETERS**

The bare minimum of parameters that must be included are:

- the code for the problem, so, **ONE** of the following (in order of precedence):
  - `problemSource` (raw pg source code, _can_ be base64 encoded)
  - `sourceFilePath` (relative to OPL `Library/`, `Contrib/`; or in `private/`)
  - `problemSourceURL` (fetch the pg source from remote server)
- a "seed" value for consistent randomization
  - `problemSeed` (integer)

| Key              | Type                             | Description                                                | Notes                                                                                                                                                                           |
| ---------------- | -------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| problemSource    | string (possibly base64 encoded) | The source code of a problem to be rendered                | Takes precedence over `sourceFilePath`.                                                                                                                                         |
| sourceFilePath   | string                           | The path to the file that contains the problem source code | Renderer will automatically adjust `Library/` and `Contrib/` relative to the webwork-open-problem-library root. Path may also begin with `private/` for local, non-OPL content. |
| problemSourceURL | string                           | The URL from which to fetch the problem source code        | Takes precedence over `problemSource` and `sourceFilePath`. A request to this URL is expected to return valid pg source code in base64 encoding.                                |
| problemSeed      | number                           | The seed that determines the randomization of a problem    |                                                                                                                                                                                 |

**ALL** other request parameters are optional.

### Infrastructure Parameters

The defaults for these parameters are set in `renderer.conf`, but these can be overridden on a per-request basis.

| Key     | Type   | Default Value                             | Description                 | Notes |
| ------- | ------ | ----------------------------------------- | --------------------------- | ----- |
| baseURL | string | '/' (as set in `renderer.conf`)           | the URL for relative paths  |       |
| formURL | string | '/render-api' (as set in `renderer.conf`) | the URL for form submission |       |

### Display Parameters

#### Formatting

Parameters that control the structure and templating of the response.

| Key          | Type   | Default Value | Description                                                   | Notes                                                                                                                   |
| ------------ | ------ | ------------- | ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| language     | string | en            | Language to render the problem in (if supported)              | affects the translation of template strings, _not_ actual problem content                                               |
| \_format     | string | 'html'        | Determine how the response is _structured_ ('html' or 'json') | usually 'html' if the user is directly interacting with the renderer, 'json' if your CMS sits between user and renderer |
| outputFormat | string | 'default'     | Determines how the problem should be formatted                | 'default', 'static', 'PTX', 'raw', or                                                                                   |
| displayMode  | string | 'MathJax'     | How to prepare math content for display                       | 'MathJax' or 'ptx'                                                                                                      |

#### User Interactions

Control how the user is allowed to interact with the rendered problem.

Requesting `outputFormat: 'static'` will prevent any buttons from being included in the rendered output, regardless of the following options.

| Key                      | Type             | Default Value  | Description                                                                                  | Notes |
| ------------------------ | ---------------- | -------------- | -------------------------------------------------------------------------------------------- | ----- |
| hidePreviewButton        | number (boolean) | false          | "Preview My Answers" is enabled by default                                                   |       |
| hideCheckAnswersButton   | number (boolean) | false          | "Submit Answers" is enabled by default                                                       |       |
| showCorrectAnswersButton | number (boolean) | `isInstructor` | "Show Correct Answers" is disabled by default, enabled if `isInstructor` is true (see below) |       |

#### Content

Control what is shown to the user: hints, solutions, attempt results, scores, etc.

| Key               | Type             | Default Value  | Description                                                                     | Notes                                                                             |
| ----------------- | ---------------- | -------------- | ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| permissionLevel   | number           | 0              | **DEPRECATED.** Use `isInstructor` instead.                                     |                                                                                   |
| isInstructor      | number (boolean) | 0              | Is the user viewing the problem an instructor or not.                           | Used by PG to determine if scaffolds can be allowed to be open among other things |
| showHints         | number (boolean) | 1              | Whether or not to show hints                                                    |                                                                                   |
| showSolutions     | number (boolean) | `isInstructor` | Whether or not to show the solutions                                            |                                                                                   |
| hideAttemptsTable | number (boolean) | 0              | Hide the table of answer previews/results/messages                              | If you have a replacement for flagging the submitted entries as correct/incorrect |
| showSummary       | number (boolean) | 1              | Determines whether or not to show a summary of the attempt underneath the table | Only relevant if the Attempts Table is shown `hideAttemptsTable: false` (default) |
| showComments      | number (boolean) | 0              | Renders author comment field at the end of the problem                          |                                                                                   |
| showFooter        | number (boolean) | 0              | Show version information and WeBWorK copyright footer                           |                                                                                   |
| includeTags       | number (boolean) | 0              | Includes problem tags in the returned JSON                                      | Only relevant when requesting `_format: 'json'`                                   |

## Using JWTs

There are three JWT structures that the Renderer uses, each containing its predecessor:

- problemJWT
- sessionJWT
- answerJWT

### ProblemJWT

This JWT encapsulates the request parameters described above, under the API heading. Any value set in the JWT cannot be
overridden by form-data. For example, if the problemJWT includes `isInstructor: 0`, then any subsequent interaction with
the problem rendered by this JWT cannot override this setting by including `isInstructor: 1` in the form-data.

### SessionJWT

This JWT encapsulates a user's attempt on a problem, including:

- the text and LaTeX versions of each answer entry
- count of incorrect attempts (stopping after a correct attempt, or after `showCorrectAnswers` is used)
- the problemJWT

If stored (see next), this JWT can be submitted as the sole request parameter, and the response will effectively restore
the users current state of interaction with the problem (as of their last submission).

### AnswerJWT

If the initial problemJWT contains a value for `JWTanswerURL`, this JWT will be generated and sent to the specified URL.
The answerJWT is the only content provided to the URL. The renderer is intended to to be user-agnostic. It is
recommended that the JWTanswerURL specify the unique identifier for the user/problem combination. (e.g. `JWTanswerURL:
'https://db.yoursite.org/grades-api/:user_problem_id'`)

For security purposes, this parameter is only accepted when included as part of a JWT.

This JWT encapsulates the status of the user's interaction with the problem.

- score
- sessionJWT

The goal here is to update the `JWTanswerURL` with the score and "state" for the user. If you have uses for additional
information, please feel free to suggest as a GitHub Issue.

## Deployer Security Notes

The renderer is intentionally dumb: it renders what it's told with the parameters it's given. It does **not** enforce
policy about who is allowed to request what — gating which inputs reach `/render-api` is the deployer's responsibility.
None of the surfaces below are renderer bugs; they're parameters the renderer trusts the caller to set responsibly.

### Surfaces that can leak correct answers

These output formats include `answers.correct_ans` for every slot in the response, with **no internal gate**:

| Parameter         | Value | Where the leak happens                                                                  |
| ----------------- | ----- | --------------------------------------------------------------------------------------- |
| `outputFormat`    | `raw` | `lib/WeBWorK/FormatRenderedProblem.pm:180` — emits the entire `$rh_result` as JSON      |
| `outputFormat`    | `ptx` | `lib/WeBWorK/FormatRenderedProblem.pm:159` — builds `answerhashXML` from `answers`      |

The `json` output format **is** internally gated (`FormatRenderedProblem.pm:289` — only includes `answers` when
`isInstructor=1`), so it's safe as long as `isInstructor` is constrained.

### Surfaces that change the trust profile of a render

| Parameter           | Risk if URL-injectable                                                                          |
| ------------------- | ----------------------------------------------------------------------------------------------- |
| `isInstructor`      | Toggles answer inclusion in `outputFormat=json`; also flips defaults for `showSolutions` etc.   |
| `showCorrectAnswers`| Renders the correct-answer reveal directly in the result summary                                |
| `problemSourceURL`  | Redirects source-fetch to an arbitrary URL (deployer should pin to their own OPL/library)       |
| `problemSource`     | Lets the caller execute arbitrary PG; intended in the peer-signed lane, hostile in any other    |
| `JWTanswerURL`      | Where answerJWTs (score + sessionJWT) are POSTed — **the renderer already gates this internally to JWT-only** since the consequence (signing scores to an attacker-controlled endpoint) is severe. The other rows are not internally gated. |

### Defense strategies

In rough order of increasing decoupling:

1. **JWT claim locking** — the issuer stamps sensitive claims into the problemJWT. The renderer's rule that "JWT claims
   override form-data" (see [ProblemJWT](#problemjwt)) prevents URL injection of those keys. Simple to deploy, but ties
   the policy to the issuer's code — a renderer shared by multiple issuers can't trust them uniformly.
2. **Reverse-proxy filter** — Caddy / nginx / CloudFront / WAF strips or rewrites disallowed query params before they
   reach `/render-api`. Decouples policy from the issuer; the deployer owns it. Composes with strategy 1.
3. **Bearer-token gating on `/render-api`** — wrap the renderer behind a service-mesh auth layer so only known callers
   can reach it. Common in multi-tenant or API-gateway deployments.
4. **Network isolation** — renderer accessible only on a private network from a trusted gateway service. Direct
   browser-to-renderer iframe flows then need a signed-URL pattern (the gateway mints, the renderer verifies).

These are not mutually exclusive; pick the combination that matches your trust model. A single-tenant LMS deployment
might use only (1). A multi-tenant CDN-fronted deployment likely uses (2) and (3). A locked-down SSR-from-backend
deployment can use (4) with no JWTs at all.

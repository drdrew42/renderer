# Renderer — Claude Code Context

WeBWorK standalone problem renderer. Executes PG (Problem Generator) code in a sandboxed Perl environment, returns rendered HTML. Content-addressed caching, Ed25519 identity, telemetry emission, federation registration.

## Architecture

**Stack**: Perl, Mojolicious (Hypnotoad prefork server), PG (submodule at `lib/PG/`)
**Entry point**: `lib/Renderer.pm` (routes, startup, content-cache wiring)
**Config**: `renderer.conf.dist` → `renderer.conf`
**Content mode**: content-addressed rendering for the LibreTexts/ADAPT deployment (the `CONTENT_ADDRESSED` path)

### Module Map

```
lib/
├── Renderer.pm                         # App entry: startup(), routes, helpers, Hypnotoad env var overrides
├── Renderer/
│   ├── Constants.pm                    # SENSITIVE_PARAMS, ANSWER_RESPONSE_*, shared string constants
│   ├── ContentCache.pm                 # Content-addressed caching: pg_hash → local disk, OPL fetch on miss
│   ├── Identity.pm                     # Ed25519 keypair: env vars → disk → generate. Fleet identity via Secrets Manager.
│   ├── Log.pm                          # Structured-JSON log formatter factory + iso8601_now helper (R38)
│   ├── OPLAuthed.pm                    # Shared verify-and-parse for OPL-signed POSTs (Callback + Audit), R34
│   ├── OPLClient.pm                    # OPL HTTP contract: URL templates, conditional GET, redirect canonicalization
│   ├── Permissions.pm                  # resolve_permissions(): single decision point for show* booleans
│   ├── Registration.pm                 # Bidirectional TOFU registration with OPL instances
│   ├── Telemetry.pm                    # In-memory buffer, 60s/100-event flush, Ed25519-signed batches to OPL
│   ├── Version.pm                      # pg_version / renderer_version helpers
│   ├── Controller/
│   │   ├── Audit.pm                    # POST /render-api/audit — OPL-signed macro audit
│   │   ├── Callback.pm                 # POST /render-api/callback — OPL-signed render probe / cache invalidation
│   │   ├── Render.pm                   # POST /render-api — thin route handler; delegates to Render::*
│   │   └── StaticFiles.pm              # Static asset serving
│   ├── Lane/
│   │   ├── Challenge.pm                # challengeJWT body lane (orchestrator-minted, WW3-032)
│   │   ├── Peer.pm                     # Peer-signed lane (Ed25519 verify, server-to-server trust)
│   │   ├── Problem.pm                  # Legacy problemJWT body lane (LMS-minted, LibreTexts/ADAPT)
│   │   ├── Session.pm                  # sessionJWT prefix lane (continuation state, claims-always-win)
│   │   └── Ungrounded.pm               # No-JWT-no-peer lane: STRICT_JWT entry gate + self-mint UX
│   ├── Render/
│   │   ├── AnswerURL.pm                # answerURL postback (legacy + challengeJWT) + post-fold (R33)
│   │   ├── ParseRequest.pm             # Envelope parse + lane dispatch (split parse_envelope/apply_lanes, R33)
│   │   ├── SourceResolver.pm           # Source resolution + content-cache fetch flow (R33)
│   │   └── Subprocess.pm               # PG execution in forked subprocess (replaced Model::Problem in R10)
│   └── Util/
│       └── JWT.pm                      # mint_jwt() — single hook point for JWT signing policy
├── WeBWorK/
│   ├── FormatRenderedProblem.pm        # HTML output formatting
│   ├── HintSolution.pm                 # Hint/solution endpoint impl (POST /render-api/{hint,solution}, R28)
│   ├── PreTeXt.pm                      # PreTeXt XML output
│   ├── RenderProblem.pm                # PG execution orchestration (calls into Renderer::Render::Subprocess)
│   ├── VerdictJWT.pm                   # Verdict-fold primitive — sessionJWT_{k+1} mint from signed verdict (WW3-053)
│   ├── Localize.pm                     # i18n
│   ├── Utils.pm                        # Misc utilities (asset URL resolution)
│   └── Utils/
│       ├── LanguageAndDirection.pm     # Locale + RTL handling
│       └── Tags.pm                     # OPL tag parsing (cold path; only when includeTags is set)
└── PG/                                 # PG submodule (math engine, macros, MathObjects) — upstream, not ours
```

### Content-Addressed Flow

1. ADAPT sends render request with `sourceFilePath` (e.g. `Library/ww_files/12345/code.pg`)
2. Renderer checks local cache at `private/problems/sha256:<hash>/problem.pg`
3. **Cache hit**: render from disk (zero network)
4. **Cache miss**: fetch source from OPL via `problemSourceURL` API, stage locally, render
5. Response includes `pg_hash` in session JWT for subsequent cache hits
6. Telemetry (render event, seed, html_hash) buffered and flushed to OPL

### Key Patterns

- **Content-addressed caching**: `ContentCache.pm` manages local problem staging. Cache is ephemeral — rebuilds on miss from OPL. No shared volumes needed.
- **Ed25519 identity**: `Identity.pm` manages keypair lifecycle. Resolution: env vars (`IDENTITY_PUBLIC_KEY_B64`/`IDENTITY_PRIVATE_KEY_B64`) → disk files → auto-generate. Env var path enables fleet-wide shared identity via AWS Secrets Manager.
- **Telemetry emission**: `Telemetry.pm` buffers render events in `@BUFFER`, flushes on 100-event threshold or 60s timer. Batches are Ed25519-signed. Fire-and-forget POST to OPL.
- **TOFU registration**: `Registration.pm` handles bidirectional trust with OPL. Renderer registers its public key + callback URL. OPL can probe back via callback endpoint.
- **Hypnotoad env vars**: `HYPNOTOAD_WORKERS`, `HYPNOTOAD_ACCEPTS`, `HYPNOTOAD_REQUESTS`, `HYPNOTOAD_SPARE`, `HYPNOTOAD_CLIENTS`, `HYPNOTOAD_GRACEFUL_TIMEOUT`. Override `renderer.conf` values.

### Authorization Model — Two Lanes, Two Gates

The renderer accepts two kinds of trusted callers:

| Lane | Trust signal | Common use |
|---|---|---|
| **JWT-bearing** | `problemJWT` / `sessionJWT` minted by a peer using shared `problemJWTsecret` | Browser-mediated render: student attempts, instructor preview of library problems, assignment delivery |
| **Peer-signed** | Ed25519 signature on the request itself (`X-Peer-Name` + `X-Peer-Timestamp` + `X-Peer-Signature` headers), peer pubkey pinned via `RENDERER_PEERS` config | Server-to-server: raw `problemSource` authoring, editor flows, asset fetches |

And two orthogonal gates govern what any given request may do:

| Gate | Mechanism | Semantics |
|---|---|---|
| **Entry** | `STRICT_JWT` env/config | When truthy, reject requests that have *neither* a JWT *nor* a valid peer signature. When falsy, ungrounded requests are permitted via self-minted JWT (legacy/VPC editor posture). |
| **Emission** | `_can_emit_answer_jwt` stash | Always active. An `answerJWT` is only emitted when the request arrived with an *upstream* problemJWT (not self-minted, not peer-signed). Peer-signed raw-source renders never emit answerJWTs — the "one-shot rule." |

**Peer-signed requests always admitted** (when registered + signature valid), regardless of `STRICT_JWT`. STRICT_JWT controls whether *ungrounded, unsigned* requests can self-mint. This lets a single strict instance serve both the browser lane (via JWT) and the editor lane (via peer signature) — valuable for single-deployment consolidation.

**Raw `problemSource` one-shot rule**: peer-signed render requests carrying raw source render one-shot only — no `sessionJWT` minted, no `answerJWT` emitted, no `pg_hash` leak to the browser. Editor-providers hold the state; every interaction is a fresh peer-signed render from their backend.

### Debug-flag vocabulary

PG's debug surfaces are gated by flags whose casing encodes *which trust source owns them* — a distinction that is invisible from the names and has bitten before (WW3-R56). Read this before touching any `show_*` / `showXxx` flag.

**The `show_*` family is a request×permission pair.** PG shows each surface only when **both** halves are truthy (`PG.pl:1500/1517/1535`, `Translator.pm:950` — e.g. `$inputs_ref->{showPGInfo} && $rh_envir->{show_pg_info}`):

| Half | Casing | Lives in | Owned by | Means |
|---|---|---|---|---|
| **Request** | camelCase — `showPGInfo`, `showAnsHashInfo`, `showAnsGroupInfo`, `showResourceInfo` | PG `inputs_ref` | **Caller** (raw request param) | "Do I want this shown *now*?" |
| **Permission** | snake_case — `show_pg_info`, `show_answer_hash_info`, `show_answer_group_info`, `show_resource_info` | PG `envir` (via `debuggingOptions`) | **`Renderer::Permissions`** (`= isInstructor`) | "Is this render *allowed* to show it?" |

Since WW3-R56 the permission half comes from `resolve_permissions` (keyed on `isInstructor`), **not** from caller input — so a caller supplies only the camelCase request half; a caller-sent snake flag is ignored. This is why the two axes are not redundant: authorization ≠ desire. Dropping the request half would dump the answer hash on every instructor preview; dropping the permission half lets a student self-grant it (the leak WW3-R56 closed). The names are PG's contract at the PG boundary — do not rename them here (fork drift). Set the permission half in `Renderer::Permissions`, never forward it from `$inputs_ref`.

**`view_problem_debugging_info` is the exception — a lone permission-half flag, deliberately caller-controlled.** PG reads it *only* from `envir` (`Translator.pm:737/756/926`, `MatrixReduce.pl`); there is **no** `viewProblemDebuggingInfo` request twin. So structurally it is a permission-half flag, but `RenderProblem.pm` sets it `$inputs_ref->{view_problem_debugging_info} // $isInstructor` — **permission as default, caller override wins**. That is intentional: it gates error *verbosity* (caught translator error text, backend non-fatal warnings) — never answers, internals, or the answer hash — so a student self-granting it is harmless, and ADAPT depends on it as a stable request lever (suppress hints via `isInstructor:0`, still get fuller error detail). **Do not fold it into the `isInstructor` permission sweep** — it is *not* a `show_*` flag despite its snake casing, and gating it away breaks the ADAPT contract (WW3-R56 carve-out).

### Cross-Origin Broadcast (`parent_origin`)

The rendered iframe broadcasts postMessage events (scores, hint clicks, focus/blur) to `window.parent`. To enable principled cross-origin embedding, the renderer accepts a `parent_origin` declaration from either trust lane:

- JWT lane: `parent_origin` as a claim on the problemJWT
- Peer-signed lane: `parent_origin` as a form-data field in the signed body

When present, templated into rendered HTML as `<html data-parent-origin="...">`. Validation is bidirectional:

- **Outbound** (`problem.js`): uses it as the target origin for every `window.parent.postMessage(data, target)` — no more wildcard `'*'`.
- **Inbound** (`css-message.js`): rejects messages whose `event.origin` doesn't match. Symmetric trust boundary — only the declared parent can inject CSS, query hints/solutions, or otherwise drive iframe state.

When absent, both directions fall back to legacy behavior: outbound uses `'*'`, inbound accepts any origin. Preserves compatibility with previews, pre-contract integrations, and the unauthenticated self-mint path.

Raw URL/body params for `parent_origin` are stripped unless they arrive inside a JWT claim or signed body — prevents unauthenticated callers from declaring arbitrary broadcast targets.

Frame identification: `problem.js` reads `window.name` (settable cross-origin via `<iframe name="...">`) before falling back to `window.frameElement` — the latter is null cross-origin.

See `LibreTexts/Renderer Secrets Migration.md`, `LibreTexts/Editor Provider Integration — Peer-Signed Render.md`, and `WeBWorK/Renderer/Trust Model and Editor Flow.md` in the vault for the full picture.

### Route Groups

| Route | Controller | Purpose |
|---|---|---|
| `POST /render-api` | Render | Core render endpoint (form-data, NOT JSON) |
| `POST /render-api/callback` | Render | OPL callback for cache invalidation + registration probe |
| `POST /render-api/audit` | Audit | OPL-signed performance audit ingestion |
| `POST /render-api/hint` | Render | Dumb content fetch (rendered hint body, R28) |
| `POST /render-api/solution` | Render | Dumb content fetch (rendered solution body, R28) |
| `ANY  /render-ptx` | Render | PreTeXt XML output (bypasses parseRequest) |
| `GET  /health` | (inline) | Health check (JSON) |
| `/pg_files/*`, `/*` | StaticFiles | Static asset serving |

**Important**: The render endpoint takes **form-data**, not JSON. This is a key discovery — documented in `WeBWorK/API Reference.md`.

## Environment Variables

| Var | Default | Purpose |
|---|---|---|
| `CONTENT_ADDRESSED` | — | Enable content-addressed mode (OPL source resolution) |
| `OPL_API_URL` | `http://webwork-opl:3000` | OPL API base URL for source fetching |
| `IDENTITY_PUBLIC_KEY_B64` | — | Ed25519 public key (base64, for fleet identity) |
| `IDENTITY_PRIVATE_KEY_B64` | — | Ed25519 private key (base64, for fleet identity) |
| `LOG_TO_STDERR` | — | Log to stderr (container mode) |
| `LOG_FORMAT` | plain | `json` for structured logging |
| `MOJO_LOG_LEVEL` | info | Log level |
| `MOJO_MODE` | — | `production` disables dev-mode editor routes |
| `STRICT_JWT` | — | Entry gate: when truthy, reject requests that are neither JWT-bearing nor peer-signed (401). Peer-signed requests are *always* accepted when the signature verifies — STRICT_JWT only governs ungrounded/unsigned requests. Public instances should set; VPC-isolated editor instances can leave unset for backward-compat (self-mint fallback). |
| `RENDERER_PEERS` | — | JSON array of `{name, public_key}` entries pinning trusted peers for the peer-signed lane. Example: `[{"name":"adapt-editor","public_key":"jEA8..."}]`. Read at startup; cluster-consistent when provided via deployment config. |
| `PRESERVE_CACHE` | — | When truthy, the container entrypoint skips the default cache-wipe at start. Operator opt-out for cases where carrying a warm cache across deploys matters more than guaranteed format-version consistency. Default behavior: wipe `private/problems/` and `private/macros/` on container start; cache rebuilds from OPL on first miss after deploy. |
| `HYPNOTOAD_WORKERS` | 10 (conf) | Worker processes |
| `HYPNOTOAD_ACCEPTS` | 400 (conf) | Max connections per worker before rotation (memory leak mitigation) |
| `HYPNOTOAD_REQUESTS` | 5 (conf) | Max requests per keep-alive connection |

## Containerization

Single-stage Dockerfile. Ubuntu 24.04, Node 22 (for PG client-side JS). Hypnotoad as production server. Health check via `curl -I localhost:3000/health`.

**Memory leak**: PG has a known memory leak. Hypnotoad rotates workers via `accepts` setting (default 400). The sawtooth pattern (leak → rotate → drop) is expected and should be visible in memory monitoring.

## Testing posture

**One entrypoint: `bash t/ci/run-all.sh`.** It builds the image, starts a container, and
runs every layer — PG unit tests (informational), the renderer Perl suite (`prove -lr t/`),
and the bash integration suites (`t/ci/0*.sh`) against a live `morbo`. CI
(`.github/workflows/test.yml`) runs the same layers. The Perl `t/*.t` layer was historically
**not** in CI — which is how the WW3-089 source-resolution regression sat broken (the
challenge/reView render tests silently could not resolve without OPL) until it was caught by
hand. It gates now.

**Run it on a Docker host, in a clean container.** On macOS the x86 image build is emulated
and slow — run it on an x86 Docker host natively. It does not run on a bare Mac (no renderer
Perl deps), and must **not** be run against a live production container: its `STRICT_JWT` /
`CONTENT_ADDRESSED` / real-OPL config breaks the test fixtures, which want a clean env.

For local iteration, unit tests with no Mojo HTTP or async-await dispatch run under a local
perl that carries the renderer's CPAN deps; **never reach for system perl** — it lacks them and
the failures are confusing. Anything needing the full stack — the render pipeline, OPL-resolved
macros, `STRICT_JWT`, the four async-await files — needs the container. See `t/CLAUDE.md` for
the tight/loose posture the suite runs under.

When smoke-testing against a deployed container, note that **secrets are read from the
container ENV, not from `renderer.conf`**: `problemJWTsecret`, `webworkJWTsecret`, and
`RENDERER_URL` all come from `$ENV` inside the container. That one costs an iteration
every time it's forgotten.

*(The local perl wrapper, the deployment host, and the container smoke recipe are in the
gitignored `CLAUDE.local.md`.)*

JS companion code (`public/js/apps/Problem/problem.js`,
`public/js/apps/CSSMessage/css-message.js`,
`public/js/apps/DraftTracker/draft-tracker.js` — ~600 lines total) has
**no JS unit-test harness** by design (WW3-R39 Phase 5 decision). JS
behavior is verified through:

1. The full-stack browser smoke path (load a rendered problem in a
   browser, exercise the feature manually).
2. Perl-side template assertions in `t/asset_config.t` that confirm the
   asset URLs land in rendered HTML.
3. Browser DevTools console + the renderer's interaction logs when the
   parent (portal/LMS) consumes postMessage events.

When changing JS, run the browser smoke for: problem load, focus/blur
events, hint/solution buttons, draft tracker keystroke debouncing,
parent→iframe CSS injection. If the JS surface grows beyond ~1k lines
or starts carrying business logic, revisit and add a Vitest/Jest harness.

## The fork boundary — two things it breaks

Per-request rendering runs in a forked subprocess:
`Renderer::Render::Subprocess::render_in_subprocess` (`Mojo::IOLoop->subprocess->run_p`).
The fork sits at the **controller → PG-render boundary**, not deep inside PG — it isolates
PG's `Safe.pm` sandbox and keeps per-render leaks out of the long-lived Hypnotoad worker.

**1. Only the return value crosses back.** The child runs
`WeBWorK::RenderProblem::process_pg_file` and `exit`s; the parent receives *only* the
Storable-serialized `$ret` hashref. So `$inputs_ref` mutations, `$c->stash` assignments, and
package globals set inside `standaloneRenderer` (or anything it calls) are **invisible to
the parent** — and the parent re-reads `$inputs_ref` afterward in
`WeBWorK::FormatRenderedProblem::formatRenderedProblem` for the format-layer primitives
(`showCorrectAnswersButton`, `hideCheckAnswersButton`, `outputFormat`, `_*` stash fields, …).

> **Rule:** anything that mutates request state and must be visible *both* inside the
> subprocess *and* in the parent afterward has to run in the controller layer,
> **before the fork** — in practice, in `ParseRequest::dispatch`.

**2. Hypnotoad's parent-only timer.** `Renderer::Telemetry::init()` is called from
`Renderer::_init_services` inside `startup()` — once, in the parent, *before* fork. Its
recurring 60s flush timer registers on the parent's `Mojo::IOLoop` and workers do **not**
reliably inherit it (only `pid 1` ever logs "Telemetry reporter: flushing…"). Compare
`Renderer::Registration::init`, which uses `Mojo::IOLoop->next_tick(...)` and *does* fire in
every worker.

Consequences: don't assume the timed flush is running when validating telemetry with
hand-rolled curl traffic — force it with a threshold burst (>100 events into one worker) or
wait. The threshold path is proven under real load. For any future Hypnotoad-resident
background work that must run in *workers*, prefer `next_tick` + a per-worker hook
(`app->hook(before_server_start => …)`) over registering timers in `startup()`.
Full hypotheses: `WeBWorK/Tasks/backlog/LTW-060 …` in the vault.

## Conventions live in the vault

The operating agreement — the renderer is dumb, validate at the boundary and gate at the
emission site, two lanes/two gates, content-addressed rendering, explicit `parent_origin` —
is gathered at `WeBWorK/Renderer/Conventions.md`, with each line linking to the doc that
elaborates it. `/warmup` loads it.

Surface friction rather than routing around it; this repo is upstream-adjacent, so
conventions here cost other people review too.

## Known Quirks

- PG is a git submodule at `lib/PG/` — update with `git submodule update`
- Dev-mode editor routes were retired in R07/R08; the controller IO.pm and Model::Problem are gone
- `renderer.conf` values are overridden by env vars, not replaced — unset vars leave config defaults intact
- Wide character encoding fixed in Ed25519 signing (`b5124895`) — `encode_utf8` before signing

## Design References

Vault docs (in Cogitari):
- `WeBWorK/Content-Addressed Problem Bundles.md` — caching architecture
- `WeBWorK/API Reference.md` — endpoint contracts (renderer + OPL)
- `WeBWorK/Render Telemetry.md` — telemetry pipeline design
- `WeBWorK/Architecture Vision.md` — where the renderer fits in the full stack

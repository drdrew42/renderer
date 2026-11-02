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
│   ├── Constants.pm                    # Strip lists (SENSITIVE/ELEVATION/RENDER_MODE/TOKEN_CONTENT/DEBUG/RETIRED_PARAMS), DEFAULT_SEED, SESSION_STATE_CLAIMS
│   ├── ContentCache.pm                 # Content-addressed caching: pg_hash → local disk, OPL fetch on miss
│   ├── Identity.pm                     # Ed25519 keypair: env vars → disk → generate. Fleet identity via Secrets Manager.
│   ├── Log.pm                          # Structured-JSON log formatter factory + iso8601_now helper (R38)
│   ├── OPLAuthed.pm                    # Shared verify-and-parse for OPL-signed POSTs (Callback, Audit, AdminInspect)
│   ├── OPLClient.pm                    # OPL HTTP contract: URL templates, conditional GET, redirect canonicalization
│   ├── Permissions.pm                  # resolve_permissions(): single decision point for show* booleans
│   ├── Registration.pm                 # Bidirectional TOFU registration with OPL; peer-signature verification
│   ├── RenderMode.pm                   # Render-mode bundles + the RATCHET (defaults → claim → raw may only tighten)
│   ├── RevealSidecar.pm                # Permission-sidecar (revealJWT) verification: play-bound grants (reveal, debug)
│   ├── Seed.pm                         # The seed rule every lane applies: absent/empty → DEFAULT_SEED + warning
│   ├── Telemetry.pm                    # In-memory buffer, 60s/100-event flush, Ed25519-signed batches to OPL
│   ├── Version.pm                      # pg_version / renderer_version helpers
│   ├── Controller/
│   │   ├── AdminInspect.pm             # POST /render-api/admin/inspect-cache — OPL-signed cache introspection
│   │   ├── Audit.pm                    # POST /render-api/audit — OPL-signed macro audit
│   │   ├── Callback.pm                 # POST /render-api/callback — OPL-signed render probe / cache invalidation
│   │   ├── Render.pm                   # /render-api, the hint/solution/answer content fetches, /render-ptx; delegates to Render::*
│   │   └── StaticFiles.pm              # Static asset serving
│   ├── Lane/
│   │   ├── Challenge.pm                # challengeJWT body lane (orchestrator-minted, WW3-032)
│   │   ├── ContentFetch.pm             # Typed problemJWT lane for /render-api/{hint,solution,answer}
│   │   ├── Peer.pm                     # Peer-signed lane (Ed25519 verify, server-to-server trust)
│   │   ├── Problem.pm                  # problemJWT body lane (LMS-minted; single-renderer integrators, LibreTexts/ADAPT)
│   │   ├── Review.pm                   # submissionJWT read-only reView replay lane (never emits)
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
└── PG/                                 # PG submodule: the drdrew42/pg fork (upstream main + the %envir commit; see Conventions)
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

### Authorization Model — Two Trust Signals, Two Gates

A request proves itself by one of two **trust signals**; `Renderer::Render::ParseRequest` then dispatches it to a **lane** — a `Renderer::Lane::*` body handler (`Problem`, `Challenge`, `Review`, `ContentFetch`, `Peer`, `Ungrounded`; `Session` is a prefix layer, not a lane). The `_trust_lane` stash carries the lane's name. Glossary: `WeBWorK/Renderer/Conventions.md`.

| Trust signal | Evidence | Lanes | Common use |
|---|---|---|---|
| **JWT** | `problemJWT`, `challengeJWT` or `submissionJWT` signed with `problemJWTsecret`; a `sessionJWT` (continuation, `webworkJWTsecret`) rides with it | Problem, Challenge, Review, ContentFetch | Browser-mediated render: student attempts, instructor preview, assignment delivery, reView |
| **Peer signature** | Ed25519 over the request (`X-Peer-Name` + `X-Peer-Timestamp` + `X-Peer-Signature`), peer pubkey pinned via `RENDERER_PEERS` | Peer | Server-to-server: raw `problemSource` authoring, editor flows |

And two orthogonal gates govern what any given request may do:

| Gate | Mechanism | Semantics |
|---|---|---|
| **Entry** | `STRICT_JWT` env/config | When truthy, reject requests that have *neither* a JWT *nor* a valid peer signature. When falsy, ungrounded requests are permitted via self-minted JWT (legacy/VPC editor posture). |
| **Emission** | `_can_emit_answer_jwt` stash | Always active. Only `Lane::Problem` and `Lane::Challenge` set it; a self-minted or peer-signed first render never does, so a submit there is a 403. |

**Peer-signed requests always admitted** (when registered + signature valid), regardless of `STRICT_JWT`. STRICT_JWT controls whether *ungrounded, unsigned* requests can self-mint. This lets a single strict instance serve both browser renders (via JWT) and editor renders (via peer signature) — valuable for single-deployment consolidation.

**Raw `problemSource` one-shot rule**: a peer-signed render of raw source emits nothing and leaves nothing gradable — no `sessionJWT`, no `answerJWT`, no `pg_hash` to the browser. `Lane::Peer` still self-mints a JWE problemJWT so the iframe can re-render and re-check, but it drops `JWTanswerURL` first, so the continuation (which arrives as `Lane::Problem`) never emits. Grading needs the content in OPL and a JWT-grounded render. Guard: `t/peer_signed.t`.

### Debug-flag vocabulary

PG's debug surfaces are gated by flags whose casing encodes *which trust source owns them* — a distinction that is invisible from the names and has bitten before (WW3-R56). Read this before touching any `show_*` / `showXxx` flag.

**The `show_*` family is a request×permission pair.** PG shows each surface only when **both** halves are truthy (`PG.pl:1500/1517/1535`, `Translator.pm:950` — e.g. `$inputs_ref->{showPGInfo} && $rh_envir->{show_pg_info}`):

| Half | Casing | Lives in | Owned by | Means |
|---|---|---|---|---|
| **Request** | camelCase — `showPGInfo`, `showAnsHashInfo`, `showAnsGroupInfo`, `showResourceInfo` | PG `inputs_ref` | **Caller** (raw request param) | "Do I want this shown *now*?" |
| **Permission** | snake_case — `show_pg_info`, `show_answer_hash_info`, `show_answer_group_info`, `show_resource_info` | PG `envir` (via `debuggingOptions`) | **`Renderer::Permissions`** (`= isInstructor`) | "Is this render *allowed* to show it?" |

Since WW3-R56 the permission half comes from `resolve_permissions` (keyed on `isInstructor`), **not** from caller input — so a caller supplies only the camelCase request half; a caller-sent snake flag is ignored. This is why the two axes are not redundant: authorization ≠ desire. Dropping the request half would dump the answer hash on every instructor preview; dropping the permission half lets a student self-grant it (the leak WW3-R56 closed). The names are PG's contract at the PG boundary — do not rename them here (fork drift). Set the permission half in `Renderer::Permissions`, never forward it from `$inputs_ref`.

**`view_problem_debugging_info` is the exception — a lone permission-half flag, honored only when signed (WW3-R58).** PG reads it *only* from `envir` (`Translator.pm:737/756/926`, `MatrixReduce.pl`); there is **no** `viewProblemDebuggingInfo` request twin. `RenderProblem.pm` sets it `$inputs_ref->{view_problem_debugging_info} // $isInstructor` — **permission as default, a signed source overrides**. On a problem that errors it prints the caught error text, backend warnings, **and the problem's full source** ("Input Read"), which carries the answer computation — so it is a privileged view. `ParseRequest` strips the raw value on grounded requests (`DEBUG_PARAMS`); it comes back only from a signed source: the problemJWT claim on the problem lane (ADAPT's request lever — suppress hints via `isInstructor:0`, still get fuller error detail), the reveal sidecar's `debug` grant on the challenge and review lanes, or a verified peer body. Ungrounded (`STRICT_JWT=0`) requests keep the raw flag. **Do not fold it into the `isInstructor` permission sweep** — it is *not* a `show_*` flag despite its snake casing, and gating it on `isInstructor` breaks the ADAPT contract.

### Cross-Origin Broadcast (`parent_origin`)

The rendered iframe broadcasts postMessage events (scores, hint clicks, focus/blur) to `window.parent`. A `parent_origin` declared in a signed source — a problemJWT claim or a peer-signed body field — is templated as `<html data-parent-origin="…">` and enforced both ways: `problem.js` targets it on every `postMessage` (never `'*'`), and `css-message.js` rejects inbound messages from any other `event.origin`. Absent, both fall back to the legacy wildcard (previews, pre-contract integrations, self-mint). A raw `parent_origin` is stripped (`SENSITIVE_PARAMS`). Frame identification reads `window.name` before `window.frameElement`, which is null cross-origin. Full contract: `WeBWorK/Renderer/postMessage Protocol.md`.

### Route Groups

| Route | Controller | Purpose |
|---|---|---|
| `ANY  /render-api` | Render | Core render endpoint (form-data, NOT JSON) |
| `POST /render-api/callback` | Callback | OPL-signed cache invalidation + render probe |
| `POST /render-api/audit` | Audit | OPL-signed macro audit |
| `POST /render-api/admin/inspect-cache` | AdminInspect | OPL-signed cache introspection |
| `POST /render-api/{hint,solution,answer}` | Render | Content fetch, gated by a typed problemJWT |
| `ANY  /render-ptx` | Render | PreTeXt XML; registered only when `ENABLE_PTX` is set |
| `ANY  /health` | (inline) | Health check (JSON) |
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
| `MOJO_MODE` | — | `development` adds the `/die` and `/timeout` test hooks |
| `RENDERER_DEBUG_FORMAT` | — | Enables `outputFormat=debug` and the JSON diagnostic envelope. Leave unset in production — it exposes PG internals |
| `ENABLE_PTX` | — | Registers `/render-ptx` (no credential gate; editor/VPC posture only) |
| `SELF_MINT_DISABLED` | — | Under `STRICT_JWT=0`, render ungrounded requests without wrapping them in a self-minted JWT |
| `STRICT_JWT` | — | Entry gate: when truthy, reject requests that are neither JWT-bearing nor peer-signed (401). Peer-signed requests are *always* accepted when the signature verifies — STRICT_JWT only governs ungrounded/unsigned requests. Public instances should set; VPC-isolated editor instances can leave unset for backward-compat (self-mint fallback). |
| `RENDERER_PEERS` | — | JSON array of `{name, public_key}` entries pinning trusted peers for the peer-signed lane. Example: `[{"name":"adapt-editor","public_key":"jEA8..."}]`. Read at startup; cluster-consistent when provided via deployment config. |
| `PRESERVE_CACHE` | — | When truthy, the container entrypoint skips the default cache-wipe at start. Operator opt-out for cases where carrying a warm cache across deploys matters more than guaranteed format-version consistency. Default behavior: wipe `private/problems/` and `private/macros/` on container start; cache rebuilds from OPL on first miss after deploy. |
| `HYPNOTOAD_WORKERS` | 10 (conf) | Worker processes |
| `HYPNOTOAD_ACCEPTS` | 10000 (conf) | Max connections per worker before a graceful recycle |
| `HYPNOTOAD_REQUESTS` | 5 (conf) | Max requests per keep-alive connection |

## Containerization

Single-stage Dockerfile. Ubuntu 24.04, Node 22 (for PG client-side JS). Hypnotoad as production server. Health check via `curl -I localhost:3000/health`.

**Worker recycling**: PG renders in a per-render forked subprocess, so its leak dies with each child. Hypnotoad `accepts` (10000) is hygiene; there is no leak sawtooth to expect in memory graphs.

## Testing posture

**One entrypoint: `bash t/ci/run-all.sh`.** It builds the image, starts a container, and
runs every layer — PG unit tests (informational), the renderer Perl suite (`prove -lr t/`),
and the bash integration suites (`t/ci/0*.sh`) against a live `morbo`. CI
(`.github/workflows/test.yml`) runs the same layers.

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

JS companion code (`problem.js`, `css-message.js`, `draft-tracker.js` under `public/js/apps/`) has **no JS unit-test harness** by design (WW3-R39). It is verified by the browser smoke — problem load, focus/blur, hint/solution buttons, draft-tracker debouncing, parent→iframe CSS injection — plus `t/asset_config.t`'s template assertions. If the JS grows past ~1k lines or starts carrying business logic, add a Vitest harness.

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
(`hideCheckAnswersButton`, `interactLabel`, `outputFormat`, `_*` stash fields, …).

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
- `Renderer::Identity` signs and verifies over UTF-8 bytes (`encode_utf8` before signing); keep the two symmetric

## Design References

Vault docs (in Cogitari):
- `WeBWorK/Content-Addressed Problem Bundles.md` — caching architecture
- `WeBWorK/API Reference.md` — endpoint contracts (renderer + OPL)
- `WeBWorK/Render Telemetry.md` — telemetry pipeline design
- `WeBWorK/Architecture Vision.md` — where the renderer fits in the full stack
- `WeBWorK/Renderer/Security Model.md` and `Parameter Reference.md` — read before touching a strip list; `t/param_surface.tsv` is the request-surface manifest

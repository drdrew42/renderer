# Renderer — Claude Code Context

WeBWorK standalone problem renderer. Executes PG (Problem Generator) code in a sandboxed Perl environment, returns rendered HTML. Content-addressed caching, Ed25519 identity, telemetry emission, federation registration.

## Architecture

**Stack**: Perl, Mojolicious (Hypnotoad prefork server), PG (submodule at `lib/PG/`)
**Entry point**: `lib/Renderer.pm` (routes, startup, content-cache wiring)
**Config**: `renderer.conf.dist` → `renderer.conf`
**Branch**: `feature/content-cache` — content-addressed mode for LibreTexts/ADAPT deployment

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
| `OPL_URL` | — | OPL API base URL for source fetching |
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

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
├── Renderer.pm                         # App entry: routes, startup, Hypnotoad env var overrides
├── Renderer/
│   ├── ContentCache.pm                 # Content-addressed caching: pg_hash → local disk, OPL fetch on miss
│   ├── Identity.pm                     # Ed25519 keypair: env vars → disk → generate. Fleet identity via Secrets Manager.
│   ├── Registration.pm                 # Bidirectional TOFU registration with OPL instances
│   ├── Telemetry.pm                    # In-memory buffer, 60s/100-event flush, Ed25519-signed batches to OPL
│   ├── Controller/
│   │   ├── Render.pm                   # Core: POST /render-api (PG execution, JWT handling, cache flow)
│   │   ├── IO.pm                       # Filesystem operations (ShowMeAnother, dev-mode editor routes)
│   │   ├── Pages.pm                    # Web UI pages (problem display, OPL browser)
│   │   └── StaticFiles.pm             # Static asset serving
│   └── Model/
│       └── Problem.pm                  # Problem model (source resolution, rendering)
├── WeBWorK/
│   ├── RenderProblem.pm               # PG execution orchestration
│   ├── FormatRenderedProblem.pm        # HTML output formatting
│   ├── PreTeXt.pm                     # PreTeXt XML output
│   └── Utils.pm, Localize.pm          # Utilities
└── PG/                                 # PG submodule (math engine, macros, MathObjects)
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

### Route Groups

| Route | Controller | Purpose |
|---|---|---|
| `POST /render-api` | Render | Core render endpoint (form-data, NOT JSON) |
| `POST /render-api/callback` | Render | OPL callback for bidirectional registration |
| `GET /health` | (inline) | Health check (JSON) |
| `GET /render-api/tap` | IO | Read problem source (dev mode only) |
| `POST /render-api/can` | IO | Write problem source (dev mode only) |
| Various `/render-api/*` | IO | Editor routes (disabled in production, `MOJO_MODE=production`) |

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
| `HYPNOTOAD_WORKERS` | 10 (conf) | Worker processes |
| `HYPNOTOAD_ACCEPTS` | 400 (conf) | Max connections per worker before rotation (memory leak mitigation) |
| `HYPNOTOAD_REQUESTS` | 5 (conf) | Max requests per keep-alive connection |

## Containerization

Single-stage Dockerfile. Ubuntu 24.04, Node 22 (for PG client-side JS). Hypnotoad as production server. Health check via `curl -I localhost:3000/health`.

**Memory leak**: PG has a known memory leak. Hypnotoad rotates workers via `accepts` setting (default 400). The sawtooth pattern (leak → rotate → drop) is expected and should be visible in memory monitoring.

## Known Quirks

- PG is a git submodule at `lib/PG/` — update with `git submodule update`
- Dev-mode routes (`supplementalRoutes`) are disabled when `MOJO_MODE=production`
- `renderer.conf` values are overridden by env vars, not replaced — unset vars leave config defaults intact
- Wide character encoding fixed in Ed25519 signing (`b5124895`) — `encode_utf8` before signing

## Design References

Vault docs (in Cogitari):
- `WeBWorK/Content-Addressed Problem Bundles.md` — caching architecture
- `WeBWorK/API Reference.md` — endpoint contracts (renderer + OPL)
- `WeBWorK/Render Telemetry.md` — telemetry pipeline design
- `WeBWorK/Architecture Vision.md` — where the renderer fits in the full stack

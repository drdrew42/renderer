# Renderer test suite — where these run, and what a local failure means

## The short version

**These are containerized tests, and the container is where the full signal lives.**
`prove -lr t/` runs green in Docker; a bare `prove` on the Mac Studio is a *partial*
signal, because four files `skip_all` on the host:

```
t/challenge_jwt.t     t/submission_jwt.t
t/reveal_reporting.t  t/peer_signed.t
```

They skip with *"Future::AsyncAwait not available (Docker-only)"* — the async runtime
they exercise ships in the container, not in the host pgperl. So on the host they are
**skipped, not failed**; in the container they run and pass. **Neither needs an OPL:**
each mints a tiny inline PGML problem and resolves it with no `pg_hash` fetch (see the
`challenge_jwt.t` fixture — *"Avoids OPL/content-cache infrastructure"*). That is what
WW3-R48 changed; the old story below is gone.

## Where the gate lives

| Runner | What it runs | Blocks? |
|---|---|---|
| **GitHub Actions** (`.github/workflows/test.yml`) | build the image, then `prove -lr t/` | ✅ **yes** — a red `t/*.t` fails the check |
| `t/ci/run-all.sh` | the same, locally against a built container — a contributor with a checkout and Docker reproduces the gate | ✅ yes |
| Bash HTTP suites (`t/ci/01-smoke`, `04-endpoints`) | end-to-end over HTTP | ◐ informational (`continue-on-error`) until WW3-R53 re-gates the drifted assertions |
| PG upstream unit tests | `t/macros`, `t/contexts`, … | ◐ informational |

The **`Test::Mojo` files in `t/` are the gating coverage** (WW3-R48). Before that fix,
`run-all.sh` never invoked `prove` against `t/`, so a change could break every
`Test::Mojo` file and still report ALL SUITES PASSED — a red test everybody had learned
to discount. Now a broken `t/*.t` turns the Actions check red.

Deployment-parity checks that need a *real* stack — the WW3↔renderer boundary, live
`STRICT_JWT` posture, real OPL content — live with the deployment-stack orchestration as a
system smoke suite, run at the end of the stack's deploy. They are closer to a system smoke
than a unit suite, and they belong there, not here.

## Tight vs. loose — the posture pair

Tight is production; loose is CI and the VPC-isolated editor. **Tight is the default in
both cases — a deployment that sets nothing is safe.**

| | tight (default) | loose |
|---|---|---|
| `STRICT_JWT` | 1 | 0 |
| `RENDERER_DEBUG_FORMAT` | unset | 1 |
| Who | students, LibreTexts, WW3 | CI, the isolated editor, this suite |

The suite is loose by construction: `t/ci/lib/helpers.sh` builds every request with
`_format=json` and asserts on `.renderedHTML` / `.JWT.problem` / `.debug`, all of which
`RENDERER_DEBUG_FORMAT` gates (WW3-R45). Subtests flip `STRICT_JWT` with `local` where
they need to. `OPL_API_URL` is deleted at file scope so no test reaches a real OPL.

> [!warning] `prove` in a *production* container reads as failure when it isn't
> `permissions.t`, `render_api.t`, and one `submission_jwt.t` subtest assert on the
> loose shape. Run them in a `STRICT_JWT=1` container (e.g. the deployed one) and they
> "fail" on the tight posture, not on a defect. Run the suite loose:
> `docker exec -e STRICT_JWT=0 -e RENDERER_DEBUG_FORMAT=1 <container> bash -c 'cd /usr/app && prove -lr t/'`

## Which host runs are meaningful

Syntax and unit-level work is fine on the host — everything except the four Docker-only
files above:

```bash
pgperl perl -c -Ilib lib/Renderer/Whatever.pm      # pgperl = the pg-perl wrapper (path in CLAUDE.local.md)
pgperl prove -Ilib -It/lib t/entry_gate.t t/render_mode.t
```

`t/entry_gate.t` (WW3-R44/R45/R46) is deliberately host-runnable — raw `problemSource`,
no hash resolution. The challenge- and review-lane guards that used to be "missing
because they need a fixture" now exist: `t/reveal_invariant.t` pins the reveal end-state
per lane × flag (WW3-R46), and `t/challenge_jwt.t` / `t/reveal_reporting.t` run in the
container.

## If you add a test

State which posture it belongs to. A test that asserts on the `_format=json` shape,
flips `STRICT_JWT`, or needs the async runtime is a containerized/loose test — say so in
a comment, so the next person reading a red local run knows whether they broke something
or just ran it tight.

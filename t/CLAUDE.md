# Renderer test suite — where these run, and what a local failure means

## The short version

**`prove -lr t/` is a full signal on the host as well as in the container**, provided the
host's pgperl carries `Future::AsyncAwait` (the async runtime `Render.pm` is built on):

```bash
pgperl prove -lr -It/lib t/
```

Files that load the async runtime guard on it and `skip_all` with *"Future::AsyncAwait not
available (Docker-only)"* where it is missing. On a host with it installed they run; a run
that reports skips is a partial signal — install the module rather than discounting them.
**None of the suite needs an OPL:** the hash-resolving files mint a tiny inline PGML problem
with no `pg_hash` fetch (see the `challenge_jwt.t` fixture — *"Avoids OPL/content-cache
infrastructure"*), which is what WW3-R48 changed.

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

## Host runs

Syntax checks and single files run on the host the same way:

```bash
pgperl perl -c -Ilib lib/Renderer/Whatever.pm      # pgperl = the pg-perl wrapper (path in CLAUDE.local.md)
pgperl prove -Ilib -It/lib t/entry_gate.t t/render_mode.t
```

`t/reveal_invariant.t` pins the reveal end-state
per lane × flag (WW3-R46); `t/challenge_jwt.t` / `t/reveal_reporting.t` cover the challenge
and review lanes.

## If you add a test

State which posture it belongs to. A test that asserts on the `_format=json` shape
or flips `STRICT_JWT` is a loose test — say so in
a comment, so the next person reading a red local run knows whether they broke something
or just ran it tight.

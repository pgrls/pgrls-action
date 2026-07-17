# pgrls-action

[![CI](https://img.shields.io/github/actions/workflow/status/pgrls/pgrls-action/test.yml?branch=main&label=tests)](https://github.com/pgrls/pgrls-action/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

GitHub Action that runs [**pgrls**](https://github.com/pgrls/pgrls) — a static analyzer for Postgres Row-Level Security — in CI, so policy bugs (broken tenant/per-user scoping, inverted auth checks, write-side holes, performance traps) fail the build instead of shipping. **67 lint rules**, 20 with mechanical auto-fixes, MIT-licensed.

Two modes:

- **`lint`** (default) — lint a *live* database's RLS state. The action installs pgrls from PyPI and runs `pgrls lint`; your workflow stands up Postgres and applies your schema/migrations first (a service container is the usual way — see [Quick start](#quick-start)).
- **`pr`** — a **DB-free pull-request gate**. Snapshots your migrations at the PR base and head (no database, no Docker) and runs `pgrls pr`: it fails the check on a **Z3-verified RLS regression** (a policy this PR loosened) *or* a new RLS finding in the changed schema, and posts a sticky review comment. See [PR gate](#pr-gate-no-database). *(Requires pgrls ≥ 0.50.0.)*

### `SEC038` — semantic anonymous-read detection (Z3-backed)

`SEC038` is the semantic sibling of the always-on `SEC004`: instead of matching the literal `auth.uid() IS NULL OR …` shape, it uses the Z3 SMT solver to *prove* that a read-capable policy's `USING` clause is unconditionally true for an unauthenticated session — catching inverted-auth variants (e.g. `NOT (auth.uid() IS NOT NULL) OR …`) that pattern-matching misses. The Z3 solver ships in pgrls's base install, so SEC038 runs out of the box — no extra setup — alongside the always-on syntactic `SEC004`. Pin `pgrls/pgrls-action@v1` to track the current rule set.

## Quick start

```yaml
name: RLS lint
on: [pull_request]

jobs:
  pgrls:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:17
        env:
          POSTGRES_PASSWORD: postgres
        ports: ["5432:5432"]
        options: >-
          --health-cmd pg_isready --health-interval 10s
          --health-timeout 5s --health-retries 5
    env:
      DATABASE_URL: postgres://postgres:postgres@localhost:5432/postgres
    steps:
      - uses: actions/checkout@v4

      # Apply your schema / migrations to the throwaway Postgres so pgrls
      # can introspect the real RLS state. Swap in your migration tool
      # (sqitch, flyway, alembic, dbmate, prisma, `psql -f schema.sql`, …).
      - run: psql "$DATABASE_URL" -f schema.sql

      - uses: pgrls/pgrls-action@v1
        with:
          schemas: public
          fail-on: error
```

`pgrls` reads `$DATABASE_URL` from the job environment automatically, so most workflows don't need the `database-url` input.

## PR gate (no database)

`mode: pr` gates a pull request on RLS **regressions** — with no database and no Docker. It snapshots your migrations directory at the PR **base** and at the **head** (offline, straight from the DDL), then runs `pgrls pr`:

- **diff (base → head)** — did this PR *loosen* an existing policy? `pgrls` proves it with Z3 (a head predicate that admits a strict superset of the base's rows is a **dangerous** regression) and fails the check.
- **lint (head)** — does the changed schema have new RLS problems (a missing `FORCE`, an inverted-auth `SEC004`/`SEC038` anon-read hole, …)?

Either crossing its threshold fails the check, and a sticky review comment is posted with the report.

```yaml
name: RLS PR gate
on: [pull_request]

permissions:
  contents: read
  pull-requests: write   # for the review comment

jobs:
  pgrls-pr:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0   # required: the base revision must be reachable

      - uses: pgrls/pgrls-action@v1
        with:
          mode: pr
          migrations: supabase/migrations   # or prisma/migrations, db/migrate, …
          # fail-on: dangerous       # diff gate (default: dangerous)
          # lint-fail-on: warning    # lint gate on the head (default: warning)
```

Because both snapshots come from the DDL, **the target database is never touched** — no service container, no `supabase start`, no secrets. Catalog-dependent rules that can't be read from DDL (index/role/function-body/foreign-key checks) are skipped and the report notes the coverage boundary, so a clean verdict is never mistaken for a full live-database audit — pair `mode: pr` with a `mode: lint` job against a live database for full coverage.

> **Layout:** `migrations` points at your migration directory; pgrls detects the ordering convention (Supabase, Prisma, Flyway, sqitch, plain-numbered). A brand-new migrations tree diffs cleanly against an empty base.

## Code scanning (SARIF)

Upload findings to GitHub code scanning so they appear in the Security tab and inline on the PR:

```yaml
      - uses: pgrls/pgrls-action@v1
        with:
          format: sarif
          output: pgrls.sarif
        # Don't let a nonzero exit skip the upload; the SARIF carries the findings.
        continue-on-error: true

      - uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: pgrls.sarif
```

The default `format: github` instead emits inline run annotations (no upload step needed).

## Supabase

[Supabase](https://supabase.com) projects keep their schema as migrations under `supabase/migrations/`, and their RLS policies lean on Supabase-provided objects — `auth.uid()`, `auth.jwt()`, the `anon` / `authenticated` roles, `request.jwt.claim.*`. pgrls is built for exactly these shapes (`SEC004` / `SEC038` catch a policy whose `USING` is true for an *unauthenticated* request; `SEC033` flags scoping on the end-user-writable `user_metadata` claim; `PERF001` flags an unwrapped `auth.uid()` re-evaluated per row).

The natural way to lint a Supabase project in CI is to stand up the local stack with the [Supabase CLI](https://github.com/supabase/setup-cli) — `supabase start` applies your migrations **and** creates the `auth` schema and roles your policies reference — then point pgrls at the local database:

```yaml
name: RLS lint (Supabase)
on: [pull_request]

jobs:
  pgrls:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      security-events: write   # required by upload-sarif
    steps:
      - uses: actions/checkout@v4

      - uses: supabase/setup-cli@v1
        with:
          version: latest

      # Boots local Postgres on :54322 and applies supabase/migrations,
      # plus the auth schema/roles your RLS policies depend on.
      - run: supabase start

      - uses: pgrls/pgrls-action@v1
        with:
          database-url: postgres://postgres:postgres@localhost:54322/postgres
          schemas: public
          format: sarif
          output: pgrls.sarif
        # SARIF carries the findings — don't let a nonzero exit skip the upload.
        continue-on-error: true

      - uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: pgrls.sarif
```

Findings show up in the **Security** tab and inline on the PR. To **fail the build** instead of (or as well as) reporting, drop the SARIF/`upload-sarif` plumbing and set `fail-on: error` (or `warning`) on the `pgrls-action` step.

> Assumes a standard Supabase project layout (a `supabase/` directory with `config.toml` and `migrations/`, as created by `supabase init`). `supabase start` runs entirely locally against Docker on the runner — no `SUPABASE_ACCESS_TOKEN` or project link needed.

## Inputs

All inputs are optional. `mode` selects which set applies.

| Input | Maps to | Default |
|---|---|---|
| `mode` | `lint` (default) or `pr` | `lint` |
| `config` | `--config` (both modes) | `./pgrls.toml` if present |
| `schemas` | `--schemas` (comma-separated) | pgrls default |
| `version` | pgrls version to install from PyPI (`pr` needs ≥ 0.50.0) | latest |
| `python-version` | `actions/setup-python` version | `3.x` |

**`mode: lint`**

| Input | Maps to | Default |
|---|---|---|
| `database-url` | `--database-url` | `$DATABASE_URL` |
| `format` | `--format` (`text`/`json`/`sarif`/`markdown`/`github`/`junit`) | `github` |
| `fail-on` | `--fail-on` (`error`/`warning`/`info`) | pgrls default (`warning`) |
| `min-severity` | `--min-severity` | — |
| `rule` | `--rule` (comma-separated → repeated) | all rules |
| `exclude-rule` | `--exclude-rule` (comma-separated → repeated) | — |
| `baseline` | `--baseline` | — |
| `output` | `--output` (write report to a file) | stdout |
| `args` | extra raw args appended to `pgrls lint` | — |

**`mode: pr`**

| Input | Maps to | Default |
|---|---|---|
| `migrations` | migrations dir, repo-relative (**required**) | — |
| `base-ref` | git ref/sha to diff against | pull_request base sha |
| `head-ref` | git ref/sha of the head | the checked-out tree |
| `fail-on` | `pr --fail-on` — diff gate (`safe`/`breaking`/`requires-review`/`dangerous`) | pgrls default (`dangerous`) |
| `lint-fail-on` | `pr --lint-fail-on` — lint gate on the head (`error`/`warning`/`info`) | pgrls default (`warning`) |
| `comment` | post/update a sticky review comment (needs `pull-requests: write`) | `true` |

## Exit behavior

The action fails the step exactly when the underlying pgrls command exits nonzero. In `lint` mode that's `pgrls lint` (default: any finding at **warning** or above); in `pr` mode that's `pgrls pr` (a **dangerous** diff regression, or a head finding at **warning** or above). Set `fail-on` / `lint-fail-on` to change the thresholds, or wrap the step with `continue-on-error: true` to report without failing. In `pr` mode the review comment is posted even when the gate fails.

## Versioning

Pin a major (`pgrls/pgrls-action@v1`) to get non-breaking updates, or a full tag (`@v1.0.0`) for an exact pin. The action installs the latest `pgrls` from PyPI unless you set the `version` input.

## License

MIT — see [LICENSE](LICENSE). pgrls itself: <https://github.com/pgrls/pgrls>.

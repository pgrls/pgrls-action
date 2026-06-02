# pgrls-action

[![CI](https://img.shields.io/github/actions/workflow/status/pgrls/pgrls-action/test.yml?branch=main&label=tests)](https://github.com/pgrls/pgrls-action/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

GitHub Action that runs [**pgrls**](https://github.com/pgrls/pgrls) — a static analyzer for Postgres Row-Level Security — against a database in CI, so policy bugs (broken tenant/per-user scoping, inverted auth checks, write-side holes, performance traps) fail the build instead of shipping. **51 lint rules**, 17 with mechanical auto-fixes, MIT-licensed.

> **pgrls lints a *live* database**, not SQL files. The action installs pgrls from PyPI and runs `pgrls lint`; your workflow is responsible for standing up a Postgres instance and applying your schema/migrations to it first (a service container is the usual way — see below).

### New in pgrls 0.16.0 — `SEC038` (semantic anonymous-read, Z3-backed)

`SEC038` is the semantic sibling of the always-on `SEC004`: instead of matching the literal `auth.uid() IS NULL OR …` shape, it uses the Z3 SMT solver to *prove* that a read-capable policy's `USING` clause is unconditionally true for an unauthenticated session — catching inverted-auth variants (e.g. `NOT (auth.uid() IS NOT NULL) OR …`) that pattern-matching misses. As of pgrls 0.16.0 the Z3 solver ships in the base install, so SEC038 runs out of the box — no extra setup — alongside the always-on syntactic `SEC004`. Pin `pgrls/pgrls-action@v1` to track the current rule set.

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

## Inputs

All inputs are optional.

| Input | Maps to | Default |
|---|---|---|
| `database-url` | `--database-url` | `$DATABASE_URL` |
| `schemas` | `--schemas` (comma-separated) | pgrls default |
| `config` | `--config` | `./pgrls.toml` if present |
| `format` | `--format` (`text`/`json`/`sarif`/`markdown`/`github`/`junit`) | `github` |
| `fail-on` | `--fail-on` (`error`/`warning`/`info`) | pgrls default (`warning`) |
| `min-severity` | `--min-severity` | — |
| `rule` | `--rule` (comma-separated → repeated) | all rules |
| `exclude-rule` | `--exclude-rule` (comma-separated → repeated) | — |
| `baseline` | `--baseline` | — |
| `output` | `--output` (write report to a file) | stdout |
| `args` | extra raw args appended to `pgrls lint` | — |
| `version` | pgrls version to install from PyPI | latest |
| `python-version` | `actions/setup-python` version | `3.x` |

## Exit behavior

The action fails the step exactly when `pgrls lint` exits nonzero. By default pgrls fails on any finding at **warning** or above; set `fail-on: error` to gate only on errors, or wrap the step with `continue-on-error: true` to report without failing.

## Versioning

Pin a major (`pgrls/pgrls-action@v1`) to get non-breaking updates, or a full tag (`@v1.0.0`) for an exact pin. The action installs the latest `pgrls` from PyPI unless you set the `version` input.

## License

MIT — see [LICENSE](LICENSE). pgrls itself: <https://github.com/pgrls/pgrls>.

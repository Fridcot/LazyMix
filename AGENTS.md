# LazyMix — agent instructions

Loaded into every session, so it holds only what must be true before any file is read.
Every rule lives in exactly one place; the table below points to the rest.

LazyMix tags tracks from a Spotify library (liked songs etc.) and builds ad-hoc playlists
from tag queries (e.g. `chill AND (jazz OR soul) NOT live`). Portfolio project, distributed
as self-hosted open source: each instance uses its own Spotify Developer app (Development
Mode: owner needs Premium, max 5 users). Stack: .NET 10 + Aspire, ASP.NET Core minimal API,
EF Core + PostgreSQL, React + TypeScript + Vite frontend, TUnit tests.

## Where the rest of the contract lives

| Where | Read when | What it holds |
|---|---|---|
| `docs/AGENTS.md` | Changing anything under `docs/` | The `describes:` marker and documentation rules |
| `docs/decisions/` | Changing architecture, boundaries, persistence, security, configuration | Architecture decision records; read the relevant ones first |
| `docs/operations/agent-workflow.md` | Any workflow skill or gate runs | What each script and skill does and why |
| `docs/operations/issue-tracking.md` | Opening, labelling or linking an issue | Labels, issue body, dependencies |
| `scripts/workflow.conf` | A gate, CI or review behaves unexpectedly | Stack paths, test projects, protected paths |

## Critical rules

- Never commit on `main`. Work on `agent/<short-description>`, preferably in a linked worktree.
- Never commit or push without an explicit request; `/finish-change` is that request.
- Stage only files that belong to the task. Preserve unrelated changes.
- Make architectural decisions before implementation; an ADR is created or changed only
  with the owner's approval.
- Never commit secrets. .NET: `dotnet user-secrets` or environment variables, never
  `appsettings*.json`.
- Everything written to the repository is in English.

## Workflow

1. `/start-task` — workspace, issue, context; returns a `safe`/`blocked` brief.
2. Implement with `scripts/verify-fast.sh` as the inner loop.
3. `/review-change` — self-review, `scripts/review-obligations.sh`, recurring findings.
4. `/finish-change` (user-invoked) — `check-docs`, verify, independent review, commit,
   push, pull request with `Closes #<issue>`.

Now and then the owner runs `/retro`, which proposes rule changes from the review and
gate history as issues.

Gates:

- `scripts/verify-fast.sh` — the local gate. Refuses `main`, requires the fetched base,
  runs only the stacks the change reaches and the unit suites it can have broken, repairs
  formatting of changed files, records a digest so an unchanged tree is not re-verified.
  Run it instead of reasoning about whether the last run still holds.
- `scripts/verify-full.sh` — optional local copy of CI (every test including the AppHost
  integration tests, which need Docker; verifying format, frontend build, workflow
  contracts).
- Never run a formatter by hand; the gates run it.
- Never present a skipped check as passed.

## Commands

```bash
dotnet tool restore              # once after clone (dotnet-ef)
aspire run                       # run everything (Postgres, migrations, API, web) + dashboard
dotnet build                     # build the solution (warnings are errors)
dotnet test                      # TUnit tests; integration tests start the AppHost (needs Docker)
dotnet ef migrations add <Name> --project src/LazyMix.Data --startup-project src/LazyMix.MigrationService
cd src/web && npm run lint       # frontend lint
```

## Layout

- `src/LazyMix.AppHost` — Aspire orchestration. Resources: `postgres`/`lazymix` db, `migrations`, `api`, `web`.
- `src/LazyMix.ServiceDefaults` — OpenTelemetry, health checks (`/health`, `/alive`), resilience, service discovery.
- `src/LazyMix.Api` — ASP.NET Core minimal API; serves the built frontend from `wwwroot` when published.
- `src/LazyMix.Data` — EF Core `LazyMixDbContext` (Npgsql), entity configurations, migrations.
- `src/LazyMix.MigrationService` — worker that applies migrations, then exits; `api` waits for it.
- `src/web` — React + TypeScript + Vite; dev server proxies `/api` to the `api` resource.
- `tests/LazyMix.Tests` — TUnit + `Aspire.Hosting.Testing`; starts the AppHost (integration suite).

## Tests and documentation

- Every behavior change, feature and bug fix comes with unit tests of observable behavior.
- Unit tests are fast, isolated and deterministic: no real clock, network, database,
  containers, filesystem or sleeps. They live in `tests/LazyMix.UnitTests` — create it,
  and add it to `LazyMix.slnx`, with the first unit test; the fast gate finds it through
  `WF_UNIT_TEST_PROJECTS`. Tests needing Docker (Aspire AppHost) stay in `tests/LazyMix.Tests`.
- Test framework: TUnit only.
- Integration tests pass `LazyMix:EphemeralDatabase=true` to the AppHost so they never
  touch the persistent dev database.
- Consult current official documentation before using or changing a library, CLI or API.
- Update the documentation a change makes stale in the same change; stale docs are a defect.
- Pin dependency versions centrally (`Directory.Packages.props`, `src/web/package-lock.json`),
  never in a `.csproj`. Move a pin only in a task that is about dependencies, and prefer
  versions at least 14 days old, except for security fixes.

## Architecture

- Tracks are identified by **ISRC** (`Track`); provider-specific IDs live in `ProviderTrack`.
  Never key domain data by Spotify IDs.
- All music-service access goes through `IMusicProvider`; Spotify is one implementation.
  Keep provider types out of the domain.
- Spotify OAuth (authorization code + PKCE) runs in the API. Tokens are stored encrypted
  (ASP.NET Data Protection) and never sent to the browser.
- Secrets (Spotify client id/secret) come from configuration: `dotnet user-secrets` in dev,
  environment variables in production.
- Common build settings live in `Directory.Build.props` (nullable, warnings as errors, code
  style enforced in build).

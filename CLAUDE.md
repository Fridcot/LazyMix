# LazyMix

Tag tracks from a Spotify library (liked songs etc.) and build ad-hoc playlists from tag queries
(e.g. `chill AND (jazz OR soul) NOT live`). Portfolio project, distributed as self-hosted open source:
each instance uses its own Spotify Developer app (Development Mode: owner needs Premium, max 5 users).

## Commands

```bash
dotnet tool restore              # once after clone (dotnet-ef)
aspire run                       # run everything (Postgres, migrations, API, web) + dashboard
dotnet build                     # build the solution (warnings are errors)
dotnet test                      # TUnit tests; integration tests start the AppHost (needs Docker)
dotnet format                    # apply .editorconfig style; run before committing
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
- `tests/LazyMix.Tests` — TUnit + `Aspire.Hosting.Testing`.

## Architecture rules

- Tracks are identified by **ISRC** (`Track`); provider-specific IDs live in `ProviderTrack`. Never key domain data by Spotify IDs.
- All music-service access goes through `IMusicProvider`; Spotify is one implementation. Keep provider types out of the domain.
- Spotify OAuth (authorization code + PKCE) runs in the API. Tokens are stored encrypted (ASP.NET Data Protection) and never sent to the browser.
- Secrets (Spotify client id/secret) come from configuration: `dotnet user-secrets` in dev, environment variables in production. Never commit them.

## Conventions

- Central package management: versions only in `Directory.Packages.props`, never in `.csproj`.
- Common build settings live in `Directory.Build.props` (nullable, warnings as errors, code style enforced in build).
- Tests: TUnit only. Integration tests pass `LazyMix:EphemeralDatabase=true` to the AppHost so they never touch the persistent dev database.
- Package updates: prefer versions at least 14 days old, except for security fixes.

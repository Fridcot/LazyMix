# LazyMix

> Too lazy to build playlists by hand? Tag your tracks once, then let LazyMix build the playlist.

LazyMix lets you tag tracks from your Spotify library (liked songs and more) and create ad-hoc
playlists from tag queries such as `chill AND (jazz OR soul) NOT live`.

**Status:** early development 🚧

## Why self-hosted?

Spotify only grants broad Web API access to registered organizations with a large user base.
Apps in Development Mode are limited to a handful of allowlisted users and require the app owner
to have Spotify Premium. LazyMix is therefore built to be self-hosted: you run your own instance
with your own (free) Spotify Developer app.

## Tech stack

- **Backend:** .NET 10, ASP.NET Core minimal API, EF Core + PostgreSQL
- **Orchestration:** [Aspire](https://aspire.dev) (local dev, telemetry dashboard, deployment manifests)
- **Frontend:** React + TypeScript + Vite (PWA)
- **Tests:** TUnit, Aspire integration testing

## Getting started

Prerequisites: [.NET 10 SDK](https://dotnet.microsoft.com/download), [Aspire CLI](https://aspire.dev),
Node.js (LTS) and Docker.

```bash
git clone https://github.com/Fridcot/LazyMix.git
cd LazyMix
aspire run
```

The Aspire dashboard link is printed in the terminal. Spotify configuration will be documented
once authentication lands.

## License

[MIT](LICENSE)

---
status: accepted
date: 2026-10-20
deciders: Fridcot
---
<!-- describes: src/LazyMix.Api/Program.cs -->

# Sign in with Spotify in the API and keep tokens encrypted server-side

## Context and problem statement

Everything LazyMix does acts on a user's Spotify library, so signing in comes first.
`AGENTS.md` fixes the frame: the OAuth flow (authorization code + PKCE) runs in the API,
Spotify tokens are stored encrypted with ASP.NET Core Data Protection and never reach the
browser, and the client id and secret come from configuration. Issue
[#4](https://github.com/Fridcot/LazyMix/issues/4) asks for the details that make this
secure and operable: the browser session, CSRF protection, where the Data Protection keys
live, token refresh, scopes, the Spotify Development Mode limits, and what signing out and
removing a user delete.

Each self-hosted instance runs its own Spotify app in Development Mode. Since the
[February 2026 migration guide](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide)
the app owner needs Premium and at most five allowlisted users may use the app;
[extended quota](https://developer.spotify.com/documentation/web-api/concepts/quota-modes)
is for organisations only, so every instance lives within these limits. The SPA and the
API share one origin: in production the API serves the built SPA from `wwwroot`, in
development the Vite dev server proxies `/api` to the API.

## Decision drivers

- A leaked database dump or backup must not give access to anyone's Spotify account.
- No Spotify token may be readable by script in the browser.
- A non-developer must be able to configure an instance with a handful of settings.
- Tokens and sessions must survive restarts and redeploys.
- Spotify constraints: redirect URIs match exactly and may not use `localhost`
  ([redirect URI rules](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri));
  refresh tokens expire six months after consent
  ([refresh token expiration](https://developer.spotify.com/blog/2026-06-18-refresh-token-expiration));
  a user who disconnects or otherwise shows the intent to stop the app's access must have
  their personal data deleted ([Developer Policy I.1.ii](https://developer.spotify.com/policy)).
- Five users at most per instance: simplicity beats horizontal scale.

## Considered options

1. **Server-side flow, cookie session, tokens encrypted in PostgreSQL**, Data Protection
   keys in PostgreSQL protected by a certificate.
2. Server-side flow with the tokens inside the authentication cookie (`SaveTokens`).
3. Browser-side PKCE flow with the tokens held by the SPA.

For the Data Protection key ring, three placements were compared: in PostgreSQL protected
by a certificate, in PostgreSQL unencrypted, and on a file-system volume.

## Decision outcome

Chosen option: **1, server-side flow with a cookie session and encrypted tokens in
PostgreSQL, keys protected by a certificate**, because it is the only option where neither
the browser nor a database dump alone yields a usable token, and it keeps the cookie small
and the session revocable.

### Sign-in flow

- The API uses the built-in ASP.NET Core OAuth handler (`AddOAuth`) as a confidential
  client: it sends the client secret **and** PKCE (`UsePkce = true`), plus `state` and a
  correlation cookie. `AspNet.Security.OAuth.Spotify` is not used: its claim mapping relies
  on profile fields Spotify deprecated in 2026 (`email`, `product`, `country`) and ignores
  `account_id`. Spotify documents neither allowing nor forbidding a token request that
  carries both the secret and a `code_verifier`. If it rejects one, the implementation
  drops the secret and runs as a public PKCE client (`client_id` and `code_verifier` on the
  token and refresh requests). The built-in handler always sends `client_secret` on the
  code exchange, so the fallback replaces the exchange in a derived handler and makes
  `Spotify:ClientSecret` optional in options validation; every other part of this decision
  stays.
- Endpoints: `GET /api/auth/login` (starts the flow), `GET /api/auth/callback` (the
  handler's callback path), `POST /api/auth/logout`, `DELETE /api/me` (remove the user).
  The callback is the only `GET` that changes state (it creates or updates the user and
  stores tokens); it is protected by `state`, the correlation cookie and PKCE instead of
  the CSRF check below.
- Scopes: `user-library-read` (liked songs) and `playlist-modify-private` (create private
  playlists and add items). The profile fields LazyMix uses need no scope;
  `user-read-private` and `user-read-email` only unlock deprecated fields and are not
  requested. A feature that needs another scope extends this list in its own change.
- During the callback the API calls `GET /me`. A user is identified by `account_id`, the
  immutable identifier Spotify recommends for account linking since
  [May 2026](https://developer.spotify.com/documentation/web-api/references/changes/may-2026),
  never by `id` and never by e-mail (no longer returned). `display_name` is stored for
  display.
- Users are internal: a LazyMix user has its own identifier; the Spotify account
  (`account_id`), its tokens and its consent time belong to a provider-account record
  owned by the Spotify implementation behind `IMusicProvider`. One provider account per
  user; signing in again on another device reuses it and replaces its tokens.

### Development Mode limits

- A user missing from the app's allowlist can usually pass `/authorize` and the token
  exchange; the first Web API call answers `403`. The callback therefore treats a `403`
  from `GET /me` as "not allowlisted": nothing is stored, and the browser is redirected to
  the sign-in screen with an error code that the SPA explains.
- An instance whose owner lost Premium is not documented to fail differently, so the same
  `403` cannot be told apart from a missing allowlist entry. Both map to one message: "Spotify
  refused access: the instance owner has to add your Spotify account in the Spotify
  Developer Dashboard and keep a Premium subscription".
- A user who refuses consent (`error=access_denied`) and any other remote failure redirect
  to the sign-in screen with their own error codes; no exception page is shown.

### Browser session

- Cookie authentication. The ticket holds only the LazyMix user id, the display name and
  the user's session stamp; the tokens are never put into it (`SaveTokens = false`).
- Cookie: `HttpOnly`, `SameSite=Lax` (`Strict` would drop the cookie on the redirect back
  from Spotify), `Secure` always outside Development, sliding expiry of 14 days.
- The OAuth handler's correlation and PKCE cookies default to `SameSite=None` with
  `Secure`, which browsers do not store over plain `http`. In Development (`http` on
  `127.0.0.1`) they use `SameSite=Lax` and `SecurePolicy=SameAsRequest`; the return from
  Spotify is a top-level `GET` navigation, which `Lax` allows.
- The session stamp is a random value stored with the user. It is regenerated whenever
  the user's Spotify token grant is deleted (sign-out, `invalid_grant`, a token that can no
  longer be decrypted), not when a sign-in replaces the tokens of a grant that still
  exists, so signing in on a second device keeps the first one signed in.
- Every request validates the principal (`OnValidatePrincipal`): the user must still
  exist, still hold a grant, and the ticket's stamp must equal the stored one. Deleting
  the grant therefore ends every session of that user on every device, and a cookie
  issued before that never becomes valid again, even after the user signs in anew. With
  at most five users the lookup per request is negligible.
- `/api` endpoints answer `401`/`403` instead of redirecting (`DisableCookieRedirect()` on
  the `/api` group).
- CSRF: .NET 10 has no built-in cross-origin protection for JSON endpoints, and
  antiforgery validates only form-bound endpoints. The API therefore:
  - never changes state on `GET`/`HEAD` except in the OAuth callback, and accepts request
    bodies only as JSON;
  - rejects every unsafe method (`POST`, `PUT`, `PATCH`, `DELETE`) under `/api` whose
    `Sec-Fetch-Site` is present and not `same-origin`, or, when `Sec-Fetch-Site` is absent,
    whose `Origin` is present and differs from `LazyMix:PublicOrigin` (the request's own
    host is not trusted: the Vite proxy and a reverse proxy rewrite it). Requests with
    neither header (non-browser clients) pass, since browsers send at least one of them on
    cross-origin requests.
  .NET 11 adds `Sec-Fetch-Site`/`Origin` protection only for form-bound endpoints, so the
  check stays for the JSON API; revisit then whether the framework's check can replace it.

### Public origin and redirect URI

- The instance's public origin is configured (`LazyMix:PublicOrigin`), never derived from
  the request: the Vite dev proxy (`changeOrigin: true`) and a production reverse proxy
  both hand the API a host the browser never used. The API builds the `redirect_uri` sent
  to Spotify from that origin plus the callback path, so the callback, the correlation
  cookie and the session cookie all belong to the origin the browser uses for the SPA.
- Development: the AppHost sets `LazyMix:PublicOrigin` to the `web` resource's URL with
  the host `127.0.0.1` (Spotify rejects `localhost`), the Vite dev server listens on
  `127.0.0.1`, and the developer opens the app at that URL, not at a `localhost` link;
  cookies set for one host are not sent to the other. The Spotify app registers
  `http://127.0.0.1/api/auth/callback` without a port, which Spotify accepts for any port
  on a loopback IP literal.
- Production: `LazyMix:PublicOrigin` is the instance's HTTPS origin and the Spotify app
  registers `https://<public host>/api/auth/callback`.

### Token storage and refresh

- Access token and refresh token are encrypted with an `IDataProtector` created for the
  purpose `LazyMix.Spotify.Tokens` and stored in the provider-account record, together
  with the access-token expiry, the granted scopes and the consent time.
- Before each Spotify call the token service returns the stored access token, refreshing
  it first when it expires within 60 seconds. A refresh that returns a new refresh token
  replaces the stored one; one that does not keeps the old one. Refreshes of one user are
  serialised in-process (one API instance; see accepted risks).
- A refresh answered with `invalid_grant` (revoked in Spotify, or past the six-month
  limit) and a stored token that can no longer be decrypted are handled the same way: the
  grant is deleted and the session stamp regenerated, the call fails as "re-authorisation
  needed", and the user's sessions end with the next request. Signing in again within
  the retention period below restores the grant and keeps the user's data.
- The consent time is stored because refresh tokens carry none; the SPA may use it to
  warn before the six-month limit.

### Data Protection keys

- Keys are persisted in PostgreSQL through `PersistKeysToDbContext<LazyMixDbContext>`
  (package `Microsoft.AspNetCore.DataProtection.EntityFrameworkCore`, a
  `DataProtectionKeys` table created by a migration), so tokens and session cookies
  survive restarts and redeploys.
- `SetApplicationName("LazyMix")`, so the key ring does not depend on the content-root
  path.
- Outside Development the keys are encrypted at rest with an X.509 certificate
  (`ProtectKeysWithCertificate`) loaded from configuration; the API refuses to start
  without it. In Development the certificate is optional: the development database holds
  only the developer's own tokens, and the framework's "no XML encryptor configured"
  warning is accepted there.
- Default key lifetime (90 days) and automatic rolling stay. Keys are never deleted.
- Replacing or losing the certificate makes the key ring unreadable: every user signs in
  again, and no data other than tokens and sessions is lost. Carrying old certificates
  over (`UnprotectKeysWithAnyCertificate`) is deferred until an instance needs it.

### Signing out and removing a user

- `POST /api/auth/logout` deletes the session cookie **and** the Spotify token grant and
  regenerates the session stamp, so a signed-out user leaves no live refresh token behind
  and every other session of that user ends too. Everything else the user owns stays for
  the retention period below.
- `DELETE /api/me` removes the user and everything the domain model
  ([#3](https://github.com/Fridcot/LazyMix/issues/3)) assigns to the user: at least the
  provider account and its tokens, and the user's library, tags and saved queries as far
  as #3 makes them per user. Data #3 keeps shared across the instance and free of
  personal data, such as the track catalogue keyed by ISRC, stays. Spotify documents no
  endpoint to revoke a grant, so the user removes the app in their Spotify account
  settings.
- Retention: the user record stores when its grant was deleted, and a sign-in that
  creates a new grant clears it. A daily background job in the API removes, exactly as
  `DELETE /api/me` does, every user whose grant has been gone for 30 days; time comes from
  `TimeProvider`. This is how the instance meets Developer Policy I.1.ii for a user who
  revokes LazyMix in their Spotify settings, which LazyMix sees only as `invalid_grant` and
  cannot tell apart from the six-month expiry, and for a user who signs out and never
  returns. The SPA says so on sign-out and on the re-authorisation prompt.

### Configuration

| Key | Purpose | Development | Production |
|---|---|---|---|
| `Spotify:ClientId` | Spotify app client id | AppHost parameter `spotify-client-id` in the AppHost's `dotnet user-secrets` (`Parameters:spotify-client-id`), passed to `api` | Environment variable `Spotify__ClientId` |
| `Spotify:ClientSecret` | Spotify app client secret | AppHost secret parameter `spotify-client-secret`, as above | Environment variable `Spotify__ClientSecret` |
| `DataProtection:CertificatePath` | PFX file that protects the key ring | Optional, `dotnet user-secrets` of the API | Environment variable `DataProtection__CertificatePath` pointing at a mounted file |
| `DataProtection:CertificatePassword` | Password of that PFX | Optional, as above | Environment variable `DataProtection__CertificatePassword` |
| `LazyMix:PublicOrigin` | Origin the browser uses; base of the redirect URI and of the `Origin` check | Set by the AppHost from the `web` resource's URL, host `127.0.0.1` | Environment variable `LazyMix__PublicOrigin`, e.g. `https://lazymix.example.org` |
| `ConnectionStrings:lazymix` | Database holding users, tokens and the key ring | Injected by Aspire | Environment variable, as decided in [#22](https://github.com/Fridcot/LazyMix/issues/22) |

These options are bound to validated options classes checked at startup
(`ValidateOnStart`): a missing client id, secret or public origin, a public origin that is
not an absolute `http`/`https` origin (or not `https` outside Development), and a missing
or unreadable certificate outside Development stop the API from starting. The redirect URI
itself is registered in the Spotify Developer Dashboard and must equal
`LazyMix:PublicOrigin` plus `/api/auth/callback` (without the port on loopback). How
production provides HTTPS and the certificate file is decided in #22.

### Threat model

Defends against:

- A leaked database dump or backup: tokens are ciphertext and the key ring is encrypted
  with a certificate that is not in the database.
- Script running in the page (XSS) reading Spotify tokens: they never reach the browser,
  and the session cookie is `HttpOnly`.
- Cross-site request forgery against the API: `SameSite=Lax`, no state change on `GET`
  outside the OAuth callback, JSON-only bodies and the `Sec-Fetch-Site`/`Origin` check.
- Authorization-code injection and login CSRF on the callback: `state`, the correlation
  cookie and PKCE.
- Users outside the instance's allowlist: they get an explanation and nothing is stored.

Accepts:

- An attacker in control of the API host or process, who holds both the database and the
  certificate, can read every token.
- A stolen session cookie works until it expires or the user's grant is deleted (sign-out,
  revocation, the six-month limit, user removal).
- Development instances may keep the key ring unencrypted.
- One API instance: refresh serialisation is in-process. Running several instances needs
  a distributed lock or tolerance of concurrent refreshes; revisit if that ever happens.
- Losing the certificate signs everyone out.
- After a disconnect the user's data is kept for up to 30 days (plus a day for the job)
  before it is deleted, because a revocation cannot be told apart from an expiry that the
  user is expected to fix by signing in again.

### Consequences

- Good: no token in the browser or the cookie; a dump alone is useless; a signed-out
  user leaves no live token; `DELETE /api/me` and the 30-day retention job delete a
  disconnected user's data as the Spotify Developer Policy requires.
- Good: the built-in handler covers `state`, correlation and PKCE; only refresh and the
  `403` mapping are hand-written.
- Neutral: one more package (`Microsoft.AspNetCore.DataProtection.EntityFrameworkCore`)
  and one more table.
- Bad: production needs a certificate in addition to the Spotify secrets, and users sign
  in again at least every six months.
- Bad: signing out on one device signs the user out everywhere.
- Bad: a user who stays signed out, or does not sign in again after the six-month expiry,
  for 30 days loses their tags and saved queries.

### Validation

- Unit tests (#7): PKCE and `state` on the authorization request, rejection of a missing
  or mismatching `state`, refresh (new and kept refresh token, `invalid_grant` deletes the
  grant), the `403` mapping, the CSRF check, the `redirect_uri` built from
  `LazyMix:PublicOrigin`, options validation, principal validation (no grant, a stale
  session stamp), and the retention job (a fake `TimeProvider` around the 30-day limit).
- A unit test of the callback that hosts the API pipeline in memory (`TestServer`) with a
  fake Spotify (`HttpMessageHandler`) and an in-memory fake of the user and token store,
  so it needs no network or database: after sign-in the response sets only the session
  cookie and no body or header carries a token.
- The AppHost integration suite does not sign in, since it has no Spotify. It passes dummy
  `Parameters:spotify-client-id` and `Parameters:spotify-client-secret` values, as it
  passes `LazyMix:EphemeralDatabase`, so the AppHost and the API's options validation
  start.
- Review: a change that adds a Spotify scope, stores a token elsewhere, derives the
  public origin from the request, or adds a state-changing `GET` other than the callback
  contradicts this ADR.

## Pros and cons of the options

### Server-side flow, cookie session, tokens encrypted in PostgreSQL

- Good, because tokens stay in the API and the cookie only identifies the user.
- Good, because sessions can be ended server-side by deleting the grant.
- Bad, because the API owns token storage, refresh and a key ring that must be backed up
  together with its certificate.

### Tokens inside the authentication cookie (`SaveTokens`)

- Good, because no token table and no per-request lookup.
- Bad, because tokens leave the server (encrypted, but in every request), the cookie grows
  towards the 4 KB limit, refresh would have to rewrite the cookie, and background work
  such as library synchronisation could not run without a browser request.

### Browser-side PKCE with tokens in the SPA

- Good, because no server-side token storage at all.
- Bad, because any XSS steals the tokens, and it contradicts the rule in `AGENTS.md`.

### Key ring in PostgreSQL, unencrypted

- Good, because nothing beyond the database is needed.
- Bad, because a dump contains both the ciphertext and the keys, which defeats encrypting
  the tokens.

### Key ring on a file-system volume

- Good, because a database dump alone holds no keys.
- Bad, because the volume must be backed up and mounted next to the database anyway, and
  a full backup of the host still contains both; a certificate is the same burden with a
  clearer boundary.

## More information

- Implementation: [#7](https://github.com/Fridcot/LazyMix/issues/7); sign-in screen:
  [#8](https://github.com/Fridcot/LazyMix/issues/8); Spotify app setup guide:
  [#9](https://github.com/Fridcot/LazyMix/issues/9); deployment:
  [#22](https://github.com/Fridcot/LazyMix/issues/22).
- [Spotify authorization code flow](https://developer.spotify.com/documentation/web-api/tutorials/code-flow),
  [PKCE flow](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow),
  [refreshing tokens](https://developer.spotify.com/documentation/web-api/tutorials/refreshing-tokens),
  [scopes](https://developer.spotify.com/documentation/web-api/concepts/scopes).
- [Data Protection key storage providers](https://learn.microsoft.com/aspnet/core/security/data-protection/implementation/key-storage-providers?view=aspnetcore-10.0),
  [key encryption at rest](https://learn.microsoft.com/aspnet/core/security/data-protection/implementation/key-encryption-at-rest?view=aspnetcore-10.0),
  [API endpoint authentication in .NET 10](https://learn.microsoft.com/aspnet/core/security/authentication/api-endpoint-auth?view=aspnetcore-10.0),
  [antiforgery](https://learn.microsoft.com/aspnet/core/security/anti-request-forgery?view=aspnetcore-10.0).
- The `describes:` marker names `Program.cs` until #7 adds the authentication code; #7
  narrows it to that code.
- Revisit on .NET 11 (framework cross-origin protection), if an instance needs more than
  one API replica, or if Spotify changes Development Mode again.

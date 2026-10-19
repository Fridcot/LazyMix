<!-- describes: none -->

# Architecture decision records

An ADR records one architectural decision: the problem, the options, the choice and its
consequences. Agents read the relevant ADRs before changing architecture, boundaries,
configuration, persistence, security-sensitive behavior or cross-cutting infrastructure.

## Rules

- A decision is proposed in a `type:decision` issue. An ADR is written or changed only
  with the owner's explicit approval (`docs/decisions/` is a protected path).
- File name: `NNNN-decision-stated-as-a-sentence.md`. Numbers are never reused; a
  withdrawn number stays a gap. Next number: **0002**.
- Use `adr-template.md`, or `adr-short-template.md` for a small decision.
- Status: `proposed` → `accepted` → (`superseded by NNNN` | `deprecated`).
- `proposed` may be edited. `accepted` is closed: a change of mind is a new ADR that
  supersedes it. The only edits to an accepted ADR are the status transition and its
  `describes:` marker.
- Every ADR carries a `describes:` marker naming the code that implements it, so a change
  to that code lists the ADR in `scripts/review-obligations.sh`.
- Issues link ADRs; they never copy them.

## Index

| ADR | Status | Decision |
|---|---|---|
| [0001](0001-sign-in-with-spotify-in-the-api-and-keep-tokens-encrypted-server-side.md) | accepted | Sign in with Spotify in the API and keep tokens encrypted server-side |

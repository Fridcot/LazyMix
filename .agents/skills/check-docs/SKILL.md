---
name: check-docs
description: Mandatory completion gate. Use when a change is nearing completion, or affects behavior, configuration, operations, documentation, dependencies, or external services. Returns pass, n/a, or fail for documentation and third-party notices.
---

# Check Documentation

Running the gate is mandatory; finding something to change is not. `n/a` and `pass` are
complete verdicts. Never widen the diff to make the gate look exercised.

## Documentation

Durable documentation describes implemented behavior; future intent lives on the issue.

1. Run `scripts/review-obligations.sh`. Its documentation section lists every page whose
   `<!-- describes: ... -->` marker covers a changed path, and whether the change
   touched that page.
2. Read each listed page and decide whether it still says something true about the part
   that moved. Update commands, examples, configuration keys, failure modes and security
   assumptions that changed.
3. A page the script did not list may still be wrong: a marker is a declaration. When you
   find such a page, widen its marker in this change.
4. A new page carries a marker within its first 15 lines (see `docs/AGENTS.md`).
5. An ADR is never created or edited without the owner's explicit approval; an accepted
   ADR is superseded, not edited.

`n/a` only when the change cannot affect user, operator, contributor, architectural or
security guidance.

## Third-party notices

For every added, upgraded, replaced or newly used package, tool, container image, model,
or copied sample:

- check its license from the official upstream source;
- prefer permissive licenses (MIT, Apache-2.0, BSD, ISC, PostgreSQL); stop and ask the
  owner before adding a copyleft (GPL, AGPL, SSPL) or source-available dependency;
- record it where `WF_REGISTER_RULES` in `scripts/workflow.conf` says (for example
  `THIRD_PARTY_NOTICES.md`) when the project keeps such a register.

`n/a` when no third-party component changed.

## Return

```text
Docs: <pass, n/a or fail — pages read and what changed>
Licenses: <pass, n/a or fail — components checked>
```

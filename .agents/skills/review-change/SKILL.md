---
name: review-change
description: Use when reviewing a working-tree diff, a branch, or a completed implementation before final verification. Findings first, ordered by severity, each with file, line, impact and the smallest correction.
---

# Review Change

## Workflow

1. Resolve the repository root and the comparison base (`scripts/inspect-workspace.sh`),
   then read the full diff: `git diff <base>...HEAD`, `git diff --cached`, `git diff`, and
   untracked files.
2. Read the `AGENTS.md` of every touched directory, the issue that governs the change,
   the ADRs and `docs/` pages that concern it.
3. Review only changed behavior and its direct consequences:
   - correctness, failure handling, cancellation, concurrency;
   - security and privacy: untrusted input bounded and validated, nothing sensitive logged;
   - architecture boundaries and naming as `AGENTS.md` states them;
   - configuration validated at startup, secrets never in `appsettings*.json`;
   - tests, documentation and third-party notices the change owes;
   - unrelated edits, generated files, secrets.
4. Run `scripts/review-obligations.sh` and confirm every row in the file it points to. A
   confirmed row is: the behavior no test now reaches (input and wrong result), the
   sentence of documentation that stopped being true, or the missing register entry. A
   row that is not confirmed is dropped, not reported. Silence from the script is not
   evidence that nothing is owed.
5. Apply the recurring findings below to the code the change touches.
6. Run `scripts/verify-fast.sh` and report its answer. An unchanged tree answers from its
   record in under a second, so run it rather than reasoning about whether it still holds.
7. Never run `dotnet format` or a frontend formatter by hand; the fast loop repairs the
   changed files.

## Recurring findings

Keep this list current: when a pull-request review (human or AI) raises the same kind of
finding twice, add it here.

- **Bounds.** Every collection read from a database, an HTTP response or a file has an
  explicit limit, enforced before the input is expanded.
- **Cancellation and time.** Async I/O takes and forwards a `CancellationToken`; time
  comes from `TimeProvider`.
- **Redaction.** Exception messages, configuration values and external responses are
  redacted before they reach a log or a span.
- **Configuration.** Options are validated (`ValidateOnStart`); a misspelled key fails
  rather than silently binding a default.
- **Tests.** No real clock, delay, network, database or shared mutable state in unit
  tests. Integration tests that need Docker live in their own project.
- **Documentation drift.** Prose describing a guarantee states what the code now does.
- **Comments.** A comment says why; no line narrates the statement beneath it.

## Reporting

Findings first, ordered by severity (P1 wrong, P2 required by a rule, P3 a later cost).
Each names the file and line, the impact, and the smallest correction. If there are no
findings, say so explicitly. Close with:

```text
Checks run: <each command and its result; anything not run, and why>
Risks left: <what this review could not rule out, or none>
```

A check that did not run is listed as not run, never as passed.

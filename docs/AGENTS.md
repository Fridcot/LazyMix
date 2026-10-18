<!-- describes: none -->

# Documentation rules

- `docs/` describes implemented behavior. Intent and plans live on issues.
- Every Markdown page under `docs/` carries exactly one marker within its first 15 lines:

  ```markdown
  <!-- describes: src/MyApp.Api/Auth/**, src/MyApp.Api/Program.cs -->
  ```

  Patterns use git glob semantics (`**/` matches zero or more directories). Name what
  makes the page stale when it changes, not everything the page mentions. A page tied to
  no code says `<!-- describes: none -->`.
- `scripts/review-obligations.sh` reports a page whenever a change touches a path its
  marker covers; `scripts/check-workflow-contracts.sh` fails a page without a marker and a
  pattern that matches no tracked file, so deleting or moving described code forces the
  marker to be updated.
- Accepted ADRs in `docs/decisions/` are never edited, only superseded (see its README).
- Pages inside `docs/` link to each other with relative links.

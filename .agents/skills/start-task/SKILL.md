---
name: start-task
description: Use when beginning repository work that may edit files, change dependencies, or need issue, documentation, or ADR context. Produces a brief that says whether the workspace is safe to edit.
---

# Start Task

Everything before the first edit: a safe workspace, the issue that governs the work, the
context that work must respect, and a brief that says `safe` or `blocked`.

## Workflow

1. Run `scripts/inspect-workspace.sh` from the repository root and read every line.
2. **Branch and worktree.** Work happens on a `agent/<short-description>` branch (the
   prefix is `WF_AGENT_BRANCH_PREFIX` in `scripts/workflow.conf`), preferably in a linked
   worktree so the developer's own checkout is never disturbed.
   - `Branch kind: harness scratch branch` (a `worktree-*` branch in a linked worktree,
     created by the harness): rename it with `git branch -m agent/<short-description>`.
     This is the expected first move.
   - `Branch kind: base branch`: never edit here. Create a worktree
     (`git worktree add ../<repo>-<short-description> -b agent/<short-description>`) or a
     branch, and continue there.
   - Never rename any other branch; it belongs to the developer.
3. **Base.** Run `scripts/inspect-workspace.sh --fetch`: it fetches the configured base
   (`WF_BASE_BRANCH`) into its tracking ref the way the gates do, then inspects again.
   `Base fetch: failed` means `blocked`. Continue only when `Contains base branch: yes`
   (or `unknown` in a repository with no remote). Otherwise rebase first.
4. **Dirty tree.** If `Working tree` is dirty, run `git status --short --untracked-files=all`
   and inventory every path. Return `blocked` until the user approves what happens to each
   one. Never assume existing changes are unrelated, and never discard them.
5. **Governing context.** Name what governs the task: an ADR, an existing issue, or
   nothing. Do not invent a governing document. Read it, the `AGENTS.md` of every directory
   the task will touch, the ADRs in `docs/decisions/` that concern the area, and the pages
   under `docs/` that describe it.
6. **Protected paths.** Check the planned change against `WF_PROTECTED_PATHS` in
   `scripts/workflow.conf`. Touching one is allowed for the owner but must be named in the
   brief, because the `Protected paths` check will flag the pull request.
7. **Issue.** Find the GitHub issue that governs the task (`gh issue list --search ...`)
   or create one following `docs/operations/issue-tracking.md`: one `type:*` label, the
   work-item template sections, and `## Dependencies`. A typo-sized change may go without
   an issue; say so in the brief.
8. **Blockers.** Read what the issue waits on:

   ```bash
   gh api repos/{owner}/{repo}/issues/<number>/dependencies/blocked_by \
     --jq '.[] | select(.state == "open") | "#\(.number) \(.title)"'
   ```

   Any line returned means `blocked`: name each blocker and what would have to close.
   An empty answer is compared against the issue's `## Dependencies` section; write any
   missing relation (`gh api -X POST .../dependencies/blocked_by -F issue_id=<id>`).
9. **Claim.** When the brief will read `safe`, mark the issue:
   `gh issue edit <number> --add-label agent:claude`.
10. **Scale.** Say whether the change looks large enough to split (several surfaces, a
    migration plus an API change, both stacks). Report it; do not refuse.
11. **External APIs.** For a dependency, CLI, protocol or external API, consult its current
    official documentation (Context7, Microsoft Learn) before planning.

## Return

```text
Status: <safe | blocked: reason>
Branch: <name> in <primary checkout | linked worktree>, base <ref> contained: <yes/no>
Issue: <#N title | created #N | none: reason>; open blockers: <none | #N ...>; claimed: <yes/no>
Governed by: <ADR / issue / nothing>
Read: <AGENTS.md files, ADRs, docs pages>
Touches protected paths: <no | list>
Split warning: <none | what makes it large, where to cut>
Open questions: <none | list>
```

Do not edit anything while the brief says `blocked`.

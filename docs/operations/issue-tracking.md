<!-- describes: .github/ISSUE_TEMPLATE/**, .github/PULL_REQUEST_TEMPLATE.md, .agents/skills/start-task/** -->

# Issue tracking

Every change that is more than a typo has a GitHub issue, and every pull request closes
one with `Closes #<number>`.

## One question, one mechanism

| Question | Mechanism |
|---|---|
| What kind of work is it? | exactly one `type:*` label |
| What does it wait on? | GitHub issue dependencies (`blocked by`), explained in `## Dependencies` |
| Which release ships it? | milestone (optional) |
| Should the task queue take it? | `agent:queue` label (removed when the queue takes it) |
| Has an agent taken it? | `agent:claude` label |
| Is it done? | closed by the merged pull request |
| What did it deliver? | acceptance items ticked by `/finish-change` |

Never answer one question with two mechanisms (for example a `blocked` label for an
ordering between two issues — that is a dependency).

## Labels

`type:*` — take the first that fits:

1. `type:decision` — an ADR, a policy, a measurement to decide something.
2. `type:defect` — behavior differs from what is documented or intended.
3. `type:docs` — documentation only (agent instructions and skills are `type:workflow`).
4. `type:workflow` — tooling, CI, scripts, agent instructions, skills.
5. `type:feature` — everything else, refactoring included.

Flags: `security` (the change needs a security review; the AI review then uses the
stronger model), `blocked` (waits on something outside the project), `agent:claude`
(applied when an agent session starts the work; never removed), `ai-review` (on a pull
request: request an AI review now), `agent:queue` (the local task queue,
`scripts/run-queue.sh`, takes the issue when it has no open blocker).

`install.sh --labels` in the agentic-workflow repository creates these labels.

## Issue body

Use the *Work item* template:

- **Context** — why the work exists; link ADRs and docs, never copy them.
- **User stories** — two or three, `As a ..., I want ..., so that ...`.
- **Acceptance** — a short checklist of observable outcomes, each checkable before the
  pull request opens. `/finish-change` ticks the items the pull request meets and lists
  the rest in the pull request.
- **Out of scope** — what a reader might expect that this issue does not do.
- **Dependencies** — the issues this waits on and why.

No estimates or dates in the body.

## Dependencies

The reason lives in `## Dependencies`; the fact lives in a relation, which `start-task`
reads before work begins:

```bash
# id (not number) of the blocking issue
blocker_id=$(gh api repos/{owner}/{repo}/issues/<blocker-number> --jq .id)
gh api -X POST repos/{owner}/{repo}/issues/<blocked-number>/dependencies/blocked_by -F issue_id="$blocker_id"
```

`-F` sends the id as a number; `-f` would send a string and fail.

## Large work

A feature too large for one pull request becomes a parent issue (title prefix `[P] `)
with sub-issues, each closed by its own pull request, and a `## Delivery order` table in
the parent listing which child waits on which.

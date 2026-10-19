<!-- describes: scripts/**, .agents/skills/**, .github/workflows/**, .github/ai-review/** -->

# Agent workflow

Deterministic operations live in scripts; judgement lives in skills. Both are shared by
every agent runtime: skills are in `.agents/skills/`, and `.claude/skills` links there.

## The cycle

| Step | Entry point | Output |
|---|---|---|
| Start | `/start-task` | brief: `safe` or `blocked`, issue, context |
| Implement | `scripts/verify-fast.sh` (repeatedly) | green fast gate |
| Self-review | `/review-change` | findings, obligations confirmed |
| Finish (user-invoked) | `/finish-change` | independent review, commit, push, pull request, acceptance ticked |
| CI | `Required CI`, `Protected paths` | required checks |
| AI review | `AI review` workflow | APPROVE or COMMENT with findings |
| Merge | the owner, squash merge only | one commit on the base branch; issue closed by `Closes #N` |
| Retrospective (user-invoked, now and then) | `/retro` | issues proposing rule changes, each citing its evidence |

`scripts/run-queue.sh` runs Start to Self-review unattended for each issue labelled
`agent:queue`, one at a time, each in its own worktree; with `WF_QUEUE_FINISH=true` it
also runs Finish. It takes only an issue whose newest `agent:queue` label was added by a
login in `WF_QUEUE_TRUSTED_ACTORS` (default: the repository owner) and whose title and
body were not edited after that; any other queued issue is skipped with a comment and
keeps its label. The agent gets the checked title and body in its prompt and stops as
`blocked` if the issue no longer matches them, and a run whose issue changed before
`/finish-change` is not finished. Comments, linked pages and the run's own access to the
machine are not covered by these checks.

## Scripts

| Script | Gates? | What it does |
|---|---|---|
| `inspect-workspace.sh` | no | Facts: branch, worktree, base, dirty tree, SDK. Read-only unless `--fetch`, which first fetches the base the way the gates do |
| `verify-fast.sh` | yes | Local gate (see `AGENTS.md`) |
| `verify-full.sh` | yes | Local copy of CI; optional |
| `run-stack.sh` | — | The build/test commands for one stack (`dotnet`, `frontend`, `custom`); used by both gates and CI |
| `resolve-changed-stacks.sh` | — | Which stacks a change reaches; used by both gates and CI |
| `resolve-changed-unit-suites.sh` | — | Which unit test projects a change can have broken |
| `review-obligations.sh` | no | Tests, docs pages and registers a change owes |
| `check-workflow-contracts.sh` | yes (CI) | Contracts on the process files themselves |
| `check-protected-paths.sh` | — | Which changed paths are protected |
| `summarize-metrics.sh` | no | Summarises the gate run log and the AI review metrics (`--fetch <n>` downloads the latest) |
| `run-queue.sh` | no | Works the `agent:queue` issues one at a time: checks who labelled one and that it was not edited since, claims it, creates its worktree, runs headless Claude Code there on the checked text, comments the outcome; stops at the first failed run. `--clean` removes the worktree and local branch of each run whose work is in the base or a merged pull request, and lists the unmerged or dirty ones it keeps |
| `collect-retro-evidence.sh` | no | The evidence `/retro` reads: gate runs, review metrics and review threads for each of `WF_RETRO_REPOSITORIES` |

All of them read `scripts/workflow.conf`.

### Verification records

A passing gate writes `artifacts/verify/<gate>.digest`: a hash of HEAD, the working tree
(tracked and untracked content) and the gate scripts. A later run over the same digest
reports the earlier run and stops. A failing run records nothing; a run whose formatter
rewrote a file records nothing and fails, so the rewrite is seen. A full-gate record also
satisfies the fast gate. `VERIFY_FORCE=1` ignores records. The base is not part of the
digest because every run fetches and re-checks it.

### Run log

Every gate run, including failed and skipped ones, appends one JSON line to
`artifacts/verify/runs.jsonl`: the stacks and suites it reached, each step's duration and
result, and the step a failure stopped in. The AI review uploads a numbers-only
`ai-review-metrics` artifact per review. `scripts/summarize-metrics.sh` reads both.

### Narrowed unit suites

A unit test project (`WF_UNIT_TEST_PROJECTS`) covers its own directory and the
directories of the projects it references directly. The fast gate runs the suites
covering the changed paths. A shared build input (`WF_SHARED_BUILD_INPUTS`) or a .NET
path no suite covers runs every unit suite. CI always runs everything.

### Base freshness

Both gates fetch the base into its tracking ref and require the branch to contain it.
CI does not check freshness (it would turn every open pull request red after each
merge); the ruleset's "require branches to be up to date" covers it at merge time.

## AI review

`.github/workflows/ai-review.yml` runs on `pull_request_target` from the base branch,
collects the pull request as data (`.github/ai-review/collect.sh`), builds the prompt
(`build-prompt.sh`), gives Claude only `Read`, `Grep` and `Glob` under the deny list in
`settings.json` with structured JSON output (`findings-schema.json`), and posts
the result from a separate job (`submit.sh`) that validates every line anchor.
`APPROVE` only when there are no findings, every collected file was read, and nothing
was truncated or excluded; otherwise `COMMENT`. Never `REQUEST_CHANGES`.

Triggers: opened, ready for review, push (cancels the running pass). Skipped: drafts,
forks and Dependabot unless the `ai-review` label is added, and pull requests that
already had `AI_REVIEW_MAX_AUTOMATIC` automatic passes. From `AI_REVIEW_SETTLE_AFTER`
passes on, only P1 findings are reported. The `security` label switches the model.

Every review carries `<!-- ai-review: automatic -->` or `<!-- ai-review: requested -->`;
the cap counts those markers on reviews written by a bot.

## Protected paths

`WF_PROTECTED_PATHS` lists the files that define how changes are judged. A pull request
touching one fails `Protected paths` unless its author is an admin; an admin's pull
request passes and lists the paths in the job summary.

#!/usr/bin/env bash
# Collects the evidence the /retro skill reads, for every repository in
# WF_RETRO_REPOSITORIES: the gate run log of a local checkout, the AI review metrics
# (through summarize-metrics.sh) and the AI review's inline findings on recent pull
# requests with the replies and resolution of each thread. Writes one JSON document;
# judges nothing. Thread text is copied as data (each comment cut to 1000 characters);
# threads and comments beyond the query's page are counted as truncated.
#
# Usage: collect-retro-evidence.sh [--prs <n>] [--review-runs <n>] [--out <file>]
#
#   --prs          recent merged or closed pull requests read per repository (default 30,
#                  at most 100)
#   --review-runs  the latest AI review runs whose metrics are downloaded per repository
#                  (default 50); runs downloaded before stay in the cache and count too
#   --out          default artifacts/retro/evidence.json
set -euo pipefail

# shellcheck source=lib/workflow.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/workflow.sh"

wf_require_jq
command -v gh >/dev/null 2>&1 || wf_fail "gh is required."

prs=30
review_runs=50
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prs) prs="${2:?--prs needs a number}"; shift 2 ;;
    --review-runs) review_runs="${2:?--review-runs needs a number}"; shift 2 ;;
    --out) out="${2:?--out needs a file}"; shift 2 ;;
    *) wf_fail "unknown argument: $1" ;;
  esac
done
[[ "$prs" =~ ^[0-9]+$ && "$review_runs" =~ ^[0-9]+$ ]] || wf_fail "--prs and --review-runs take numbers."
[[ "$prs" -ge 1 && "$prs" -le 100 ]] || wf_fail "--prs takes 1 to 100 (one GraphQL page)."
[[ -z "$out" || "$out" == /* ]] || out="$PWD/$out"
cd "$WF_ROOT"
[[ -n "$out" ]] || out="$WF_ROOT/artifacts/retro/evidence.json"

repositories=("${WF_RETRO_REPOSITORIES[@]}")
if [[ ${#repositories[@]} -eq 0 ]]; then
  current="$WF_BASE_REPOSITORY"
  [[ -n "$current" ]] || current="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
  repositories=("$current=$WF_ROOT")
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cache="$WF_ROOT/artifacts/retro/reviews"

# Bot-started review threads on the last $prs pull requests, flattened to one object
# per finding. The first comment carries the finding (`**P1 · title**`), the rest are
# replies.
threads_query='
query($owner: String!, $name: String!, $n: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequests(last: $n, states: [MERGED, CLOSED]) {
      nodes {
        number url state
        reviewThreads(first: 100) {
          totalCount
          nodes {
            isResolved isOutdated
            comments(first: 30) { totalCount nodes { author { login __typename } body url path } }
          }
        }
      }
    }
  }
}'

: >"$work/repositories.jsonl"
for entry in "${repositories[@]}"; do
  repository="${entry%%=*}"
  path=""
  [[ "$entry" != *=* ]] || path="${entry#*=}"
  [[ "$repository" == */* ]] || wf_fail "WF_RETRO_REPOSITORIES entry '$entry' is not owner/name[=path]."
  path="${path/#\~/$HOME}"
  [[ -z "$path" || "$path" == /* ]] || path="$WF_ROOT/$path"
  [[ -z "$path" || -d "$path" ]] || wf_fail "the checkout of $repository does not exist: $path"
  wf_info "Collecting $repository${path:+ (gate log from $path)}" >&2

  runs_file="${path:+$path/artifacts/verify/runs.jsonl}"
  [[ -n "$runs_file" ]] || runs_file="$work/none.jsonl"
  scripts/summarize-metrics.sh --repo "$repository" --runs "$runs_file" \
    --reviews "$cache/${repository//\//__}" --fetch "$review_runs" --json >"$work/summary.json"

  gh api graphql -f query="$threads_query" -f owner="${repository%%/*}" -f name="${repository#*/}" -F n="$prs" \
    >"$work/threads.json"

  jq -c --arg repository "$repository" --arg path "$path" --slurpfile summary "$work/summary.json" '
    def cut: if . == null then null else .[:1000] end;
    {
      repository: $repository,
      local_checkout: (if $path == "" then null else $path end),
      gates: (if $path == "" then null else $summary[0].gates end),
      reviews: $summary[0].reviews,
      pull_requests_read: (.data.repository.pullRequests.nodes | length),
      truncated: {
        threads: ([ .data.repository.pullRequests.nodes[].reviewThreads | .totalCount - (.nodes | length) ] | add // 0),
        comments: ([ .data.repository.pullRequests.nodes[].reviewThreads.nodes[].comments | .totalCount - (.nodes | length) ] | add // 0)
      },
      findings: [
        .data.repository.pullRequests.nodes[] as $pr
        | $pr.reviewThreads.nodes[]
        | select(.comments.nodes[0].author.__typename == "Bot")
        | (.comments.nodes[0]) as $first
        | ($first.body | capture("^\\*\\*(?<severity>P[123]) · (?<title>[^\n]+)\\*\\*(\n|$)")) as $head
        | {
            pull_request: $pr.number,
            pull_request_url: $pr.url,
            pull_request_state: $pr.state,
            severity: $head.severity,
            title: $head.title,
            rule: (($first.body | capture("\\*\\*Rule:\\*\\* (?<rule>[^\n]+)").rule) // null),
            path: $first.path,
            url: $first.url,
            body: ($first.body | cut),
            resolved: .isResolved,
            outdated: .isOutdated,
            replies: [ .comments.nodes[1:][] | { author: .author.login, bot: (.author.__typename == "Bot"), body: (.body | cut) } ]
          }
      ]
    }' "$work/threads.json" >>"$work/repositories.jsonl"
done

mkdir -p "$(dirname "$out")"
jq -s --arg collected "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson prs "$prs" --argjson review_runs "$review_runs" \
  '{schema: 1, collected_at: $collected, limits: {pull_requests: $prs, review_runs_fetched: $review_runs}, repositories: .}' \
  "$work/repositories.jsonl" >"$out"
jq -r '.repositories[] | "\(.repository): \(.findings | length) finding thread(s) on \(.pull_requests_read) pull request(s), \(.reviews.reviews) review metric(s), \(if .gates then "\(.gates.runs) gate run(s)" else "no local gate log" end)"' "$out"
echo "Evidence: ${out#"$WF_ROOT"/}"

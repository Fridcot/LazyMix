#!/usr/bin/env bash
# Summarises the workflow's evidence: the gate run log (artifacts/verify/runs.jsonl,
# appended by verify-fast.sh and verify-full.sh) and the AI review metrics (one
# numbers-only JSON document per review, uploaded as the `ai-review-metrics` artifact).
#
# Usage: summarize-metrics.sh [--runs <runs.jsonl>] [--reviews <dir>] [--fetch <n>]
#                             [--repo <owner/name>] [--json]
#
#   --runs     the gate run log (default artifacts/verify/runs.jsonl)
#   --reviews  a directory searched for review metrics documents
#              (default artifacts/metrics/reviews)
#   --fetch    first download the metrics of the last <n> AI review runs into the
#              reviews directory (gh; runs already downloaded are kept)
#   --repo     the repository --fetch reads (default WF_BASE_REPOSITORY, else gh's own)
#   --json     print the summary as JSON instead of text
#
# A missing source is reported as empty, never as an error; lines or documents that
# do not parse are skipped and counted.
set -euo pipefail

# shellcheck source=lib/workflow.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/workflow.sh"

wf_require_jq

# Relative paths are taken from where the script was called, not the repository root.
absolute() { if [[ "$1" == /* ]]; then printf '%s' "$1"; else printf '%s/%s' "$PWD" "$1"; fi; }

runs="$WF_RUN_LOG"
reviews="$WF_ROOT/artifacts/metrics/reviews"
fetch=""
repository="$WF_BASE_REPOSITORY"
format=text
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) runs="$(absolute "${2:?--runs needs a file}")"; shift 2 ;;
    --reviews) reviews="$(absolute "${2:?--reviews needs a directory}")"; shift 2 ;;
    --fetch) fetch="${2:?--fetch needs a number}"; shift 2 ;;
    --repo) repository="${2:?--repo needs owner/name}"; shift 2 ;;
    --json) format=json; shift ;;
    *) wf_fail "unknown argument: $1" ;;
  esac
done
cd "$WF_ROOT"

if [[ -n "$fetch" ]]; then
  [[ "$fetch" =~ ^[0-9]+$ ]] || wf_fail "--fetch needs a number, got '$fetch'."
  command -v gh >/dev/null 2>&1 || wf_fail "--fetch needs gh."
  repo_args=()
  [[ -z "$repository" ]] || repo_args=(--repo "$repository")
  # Listed first, outside a process substitution, so a failing gh fails the script.
  run_ids="$(gh run list "${repo_args[@]}" --workflow ai-review.yml --limit "$fetch" --json databaseId --jq '.[].databaseId')"
  mkdir -p "$reviews"
  downloaded=0
  while IFS= read -r run_id; do
    [[ -n "$run_id" && ! -d "$reviews/$run_id" ]] || continue
    # A run that reviewed nothing (skipped, cancelled, not configured) has no artifact.
    if gh run download "$run_id" "${repo_args[@]}" --name ai-review-metrics --dir "$reviews/$run_id" >/dev/null 2>&1; then
      downloaded=$((downloaded + 1))
    else
      rm -rf "${reviews:?}/$run_id"
    fi
  done <<<"$run_ids"
  wf_info "Fetched the metrics of $downloaded review run(s) into $reviews." >&2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

: >"$work/runs.jsonl"
if [[ -f "$runs" ]]; then
  cp "$runs" "$work/runs.jsonl"
fi
: >"$work/reviews.jsonl"
if [[ -d "$reviews" ]]; then
  while IFS= read -r -d '' document; do
    # One compact line per document; a document that does not parse becomes a marker.
    jq -c . "$document" 2>/dev/null >>"$work/reviews.jsonl" || echo '"unreadable"' >>"$work/reviews.jsonl"
  done < <(find "$reviews" -type f -name '*.json' -print0 | sort -z)
fi

summary="$(jq -n \
  --rawfile runs "$work/runs.jsonl" \
  --rawfile reviews "$work/reviews.jsonl" \
  --arg runs_source "${runs#"$WF_ROOT"/}" \
  --arg reviews_source "${reviews#"$WF_ROOT"/}" '
  def parsed: split("\n") | map(select(length > 0) | (fromjson? // "unreadable"));
  # Nearest rank: the smallest value with at least $p of the values at or below it.
  def pct($p): sort | if length == 0 then null else .[([(length * $p | ceil) - 1, 0] | max)] end;
  def round1: if . == null then null else (. * 10 | round) / 10 end;
  def counts: group_by(.) | map({ key: (.[0] | tostring), value: length }) | from_entries;

  ($runs | parsed) as $all_runs
  | [ $all_runs[] | objects | select(.schema == 1) ] as $r
  | ($reviews | parsed) as $all_reviews
  | [ $all_reviews[] | objects | select(.schema == 1) ] as $v
  | {
      gates: {
        source: $runs_source,
        runs: ($r | length),
        unreadable: (($all_runs | length) - ($r | length)),
        first: ([ $r[].started_at ] | min),
        last: ([ $r[].started_at ] | max),
        by_gate: ($r | group_by(.gate) | map({
          key: .[0].gate,
          value: {
            runs: length,
            pass: (map(select(.result == "pass")) | length),
            fail: (map(select(.result == "fail")) | length),
            skipped_by_record: (map(select(.skipped_by_record)) | length),
            pass_seconds_median: ([ .[] | select(.result == "pass") | .duration_seconds ] | pct(0.5) | round1),
            pass_seconds_p90: ([ .[] | select(.result == "pass") | .duration_seconds ] | pct(0.9) | round1)
          }
        }) | from_entries),
        failures_by_step: ([ $r[] | select(.result == "fail") | (.failed_step // "unknown") ] | counts),
        step_seconds_median: ([ $r[] | (.steps // [])[] | select(.result == "pass") ] | group_by(.name)
          | map({ key: .[0].name, value: (map(.seconds) | pct(0.5) | round1) }) | from_entries)
      },
      reviews: {
        source: $reviews_source,
        reviews: ($v | length),
        unreadable: (($all_reviews | length) - ($v | length)),
        pull_requests: ([ $v[] | "\(.repository)#\(.pull_request)" ] | unique | length),
        events: ([ $v[].event ] | counts),
        complete_readings: ([ $v[] | select(.complete) ] | length),
        findings: {
          P1: ([ $v[].findings.P1 ] | add // 0),
          P2: ([ $v[].findings.P2 ] | add // 0),
          P3: ([ $v[].findings.P3 ] | add // 0),
          total: ([ $v[].findings.total ] | add // 0)
        },
        anchored: ([ $v[].anchored ] | add // 0),
        in_body: ([ $v[].in_body ] | add // 0),
        files_collected: ([ $v[].files.collected ] | add // 0),
        files_read: ([ $v[].files.read ] | add // 0),
        truncated_reviews: ([ $v[] | select(.truncated > 0) ] | length),
        duration_seconds_median: ([ $v[].duration_seconds | numbers ] | pct(0.5) | round1),
        duration_seconds_p90: ([ $v[].duration_seconds | numbers ] | pct(0.9) | round1),
        passes_per_pull_request_max: ([ $v[] | .pass | numbers ] | max),
        by_model: ($v | group_by(.model) | map({
          key: .[0].model,
          value: {
            reviews: length,
            findings_per_review: ((map(.findings.total // 0) | add) / length | round1)
          }
        }) | from_entries)
      }
    }')"

if [[ "$format" == json ]]; then
  jq . <<<"$summary"
  exit 0
fi

jq -r '
  def pairs: to_entries | map("\(.key) \(.value)") | join(" · ");
  def or_dash: if . == null then "-" else tostring end;
  .gates as $g
  | .reviews as $v
  | [
      "Gate runs: \($g.source) — \($g.runs) run(s)"
        + (if $g.runs > 0 then ", \($g.first) to \($g.last)" else "" end)
        + (if $g.unreadable > 0 then ", \($g.unreadable) unreadable line(s) skipped" else "" end),
      ($g.by_gate | to_entries[] | "  \(.key): \(.value.runs) run(s) · pass \(.value.pass) · fail \(.value.fail) · skipped by record \(.value.skipped_by_record) · passing run median \(.value.pass_seconds_median | or_dash) s, p90 \(.value.pass_seconds_p90 | or_dash) s"),
      (if ($g.failures_by_step | length) > 0 then "  failures by step: \($g.failures_by_step | pairs)" else empty end),
      (if ($g.step_seconds_median | length) > 0 then "  median seconds per passing step: \($g.step_seconds_median | pairs)" else empty end),
      "",
      "AI reviews: \($v.source) — \($v.reviews) review(s) of \($v.pull_requests) pull request(s)"
        + (if $v.unreadable > 0 then ", \($v.unreadable) unreadable document(s) skipped" else "" end),
      (if $v.reviews > 0 then
        "  events: \($v.events | pairs) · complete readings \($v.complete_readings)",
        "  findings: P1 \($v.findings.P1) · P2 \($v.findings.P2) · P3 \($v.findings.P3) · anchored inline \($v.anchored) of \($v.findings.total)",
        "  files read: \($v.files_read) of \($v.files_collected) collected · truncated reviews \($v.truncated_reviews)",
        "  duration: median \($v.duration_seconds_median | or_dash) s, p90 \($v.duration_seconds_p90 | or_dash) s · most passes on one pull request \($v.passes_per_pull_request_max | or_dash)",
        ($v.by_model | to_entries[] | "  \(.key): \(.value.reviews) review(s), \(.value.findings_per_review) finding(s) per review")
      else empty end)
    ] | .[]' <<<"$summary"

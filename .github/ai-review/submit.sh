#!/usr/bin/env bash
# Publishes the AI review deterministically. The model only produced JSON; this script
# validates every anchor against the lines the patch shows, renders the comments,
# computes the tally itself and submits one review. It never retries the submission
# (a review is not idempotent) and never requests changes, so it cannot block a merge.
#
# With METRICS_FILE set it also writes the review's numbers there (counts, the model,
# the pass number, the duration; never model text) for scripts/summarize-metrics.sh.
#
# Usage: submit.sh <findings.json> <input-dir>
# Environment: GH_TOKEN, REPOSITORY, NUMBER, HEAD_SHA, TRIGGER (automatic|requested),
#              MODEL, POSTURE, PASS, METRICS_FILE, DRY_RUN (1 prints the payload instead
#              of posting)
set -euo pipefail

findings_file="${1:?usage: submit.sh <findings.json> <input-dir>}"
input="${2:?usage: submit.sh <findings.json> <input-dir>}"
: "${REPOSITORY:?}" "${NUMBER:?}" "${HEAD_SHA:?}"
trigger="${TRIGGER:-automatic}"
model="${MODEL:-unknown}"
posture="${POSTURE:-full}"
pass="${PASS:-}"

if ! jq -e '(.summary | type == "string") and (.findings | type == "array") and (.covered | type == "array")' \
  "$findings_file" >/dev/null 2>&1; then
  echo "::error::The review produced no usable findings document; nothing is published." >&2
  exit 1
fi

# Model text derived from an untrusted diff must never carry a credential out.
credential='(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16})'
if grep -Eq -- "$credential" "$findings_file"; then
  echo "::error::A finding contains something shaped like a credential; the review is withheld." >&2
  exit 1
fi

[[ -f "$input/excluded.txt" ]] || : >"$input/excluded.txt"
duration="$(cat "$input/duration.txt" 2>/dev/null || true)"

result="$(jq -n \
  --slurpfile review "$findings_file" \
  --slurpfile lines "$input/lines.json" \
  --slurpfile files "$input/files.json" \
  --rawfile truncation "$input/truncation.txt" \
  --rawfile excluded "$input/excluded.txt" \
  --arg head "$HEAD_SHA" --arg trigger "$trigger" --arg model "$model" \
  --arg posture "$posture" --arg pass "$pass" --arg duration "$duration" \
  --arg repository "$REPOSITORY" --arg number "$NUMBER" '
  def number_or_null: rtrimstr("\n") | if test("^[0-9]+$") then tonumber else null end;
  def lines_of: rtrimstr("\n") | split("\n") | map(select(length > 0));
  ($review[0]) as $r
  | ($lines[0]) as $l
  | def hunk_of($path; $line): [ ($l[$path] // [])[] | select(.line == $line) | .hunk ] | first;
    def anchored($f): $f.path != null and $f.line != null and hunk_of($f.path; $f.line) != null;
    # A range is kept only within one hunk; otherwise the comment sits on its last line.
    def ranged($f):
      $f.start_line != null and $f.start_line < $f.line
      and hunk_of($f.path; $f.start_line) == hunk_of($f.path; $f.line);
    def render($f):
      "**\($f.severity) · \($f.title)**\n\n**Impact:** \($f.impact)\n\n**Correction:** \($f.correction)\n\n**Rule:** \($f.rule)";
  [ $r.findings[] | select(anchored(.)) ] as $inline
  | [ $r.findings[] | select(anchored(.) | not) ] as $loose
  | ([ $files[0][].filename ] - $r.covered) as $unread
  | ($r.findings | length) as $count
  # A pull request with nothing reviewable (only excluded paths) is never approved.
  | ($count == 0 and ($files[0] | length) > 0 and ($unread | length) == 0
     and ($truncation | length) == 0 and ($excluded | length) == 0) as $complete
  | {
    payload: {
      commit_id: $head,
      # Approve only a complete reading: no findings, every file read, nothing truncated
      # and nothing excluded (an excluded lock file or migration still needs a human).
      event: (if $complete then "APPROVE" else "COMMENT" end),
      body: (
        [ (if $complete then "# APPROVED"
           elif $count == 0 then "# NO FINDINGS (INCOMPLETE READING)"
           else "# NEEDS CHANGES" end),
          $r.summary,
          (if $count > 0 then
             "Findings: " + ([ "P1", "P2", "P3" ] | map(. as $s | "\($s) \([ $r.findings[] | select(.severity == $s) ] | length)") | join(" · "))
           else empty end),
          (if ($loose | length) > 0 then
             "## Findings with no line to sit on\n\n" + ([ $loose[] | (if .path then "`\(.path)`" + (if .line then ":\(.line)" else "" end) + " — " else "" end) + render(.) ] | join("\n\n---\n\n"))
           else empty end),
          (if ($unread | length) > 0 then
             "## Not read in this pass\n\n" + ($unread | map("- `\(.)`") | join("\n"))
           else empty end),
          (if ($excluded | length) > 0 then "## Not reviewed by configuration\n\n" + ($excluded | rtrimstr("\n") | split("\n") | map("- `" + . + "`") | join("\n")) else empty end),
          (if ($truncation | length) > 0 then "## Not collected\n\n" + ($truncation | rtrimstr("\n") | split("\n") | map("- " + .) | join("\n")) else empty end),
          "<sub>AI review · \($model)</sub>\n<!-- ai-review: \($trigger) -->"
        ] | join("\n\n")
      ),
      comments: [ $inline[] | {
          path, line, side: "RIGHT", body: render(.)
        } + (if ranged(.) then { start_line, start_side: "RIGHT" } else {} end) ]
    },
    # Numbers and identifiers only; nothing the model wrote.
    metrics: {
      schema: 1,
      repository: $repository,
      pull_request: ($number | number_or_null),
      head_sha: $head,
      pass: ($pass | number_or_null),
      trigger: $trigger,
      posture: $posture,
      model: $model,
      event: (if $complete then "APPROVE" else "COMMENT" end),
      complete: $complete,
      findings: ({ total: $count } + ([ "P1", "P2", "P3" ] | map(. as $s | { ($s): ([ $r.findings[] | select(.severity == $s) ] | length) }) | add)),
      anchored: ($inline | length),
      in_body: ($loose | length),
      files: {
        collected: ($files[0] | length),
        read: (($files[0] | length) - ($unread | length)),
        unread: ($unread | length),
        excluded: ($excluded | lines_of | length)
      },
      truncated: ($truncation | lines_of | length),
      duration_seconds: ($duration | number_or_null)
    }
  }')"
payload="$(jq -c .payload <<<"$result")"

if [[ -n "${METRICS_FILE:-}" ]]; then
  jq '.metrics + { created_at: (now | todate) }' <<<"$result" >"$METRICS_FILE"
fi

if [[ "${DRY_RUN:-0}" == 1 ]]; then
  echo "$payload"
  exit 0
fi

gh api "repos/$REPOSITORY/pulls/$NUMBER/reviews" --method POST --input - <<<"$payload" >/dev/null
echo "Published: $(jq -r .event <<<"$payload") with $(jq '.comments | length' <<<"$payload") inline comment(s)."

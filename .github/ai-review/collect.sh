#!/usr/bin/env bash
# Collects a pull request as data for the AI review: metadata, the patch, the head
# version of each changed file, the lines a comment may anchor to, earlier AI reviews
# and the conversation, and the obligations index. Runs in a checkout of the BASE
# commit; nothing from the head is ever executed.
#
# Usage: collect.sh <output-dir>
# Environment: GH_TOKEN, REPOSITORY, NUMBER, HEAD_SHA
set -euo pipefail

out="${1:?usage: collect.sh <output-dir>}"
: "${REPOSITORY:?}" "${NUMBER:?}" "${HEAD_SHA:?}"

# shellcheck source=../../scripts/lib/workflow.sh
source scripts/lib/workflow.sh
wf_require_jq

MAX_FILES=100
MAX_FILE_BYTES=131072
MAX_COMMENTS=100
MAX_COMMENT_CHARS=2000

mkdir -p "$out/head"
# truncation.txt: input that was lost (the review cannot approve).
# excluded.txt: paths the configuration says are never reviewed (informational).
: >"$out/truncation.txt"
: >"$out/excluded.txt"

gh api "repos/$REPOSITORY/pulls/$NUMBER" \
  --jq '{number, title, body, author: .user.login, base: .base.ref, head: .head.sha, draft}' \
  >"$out/pull-request.json"

# The file list comes from the pull request's current state and the contents from
# HEAD_SHA; if a push moved the head since the event, the two would disagree. The push
# started a newer run, so this one stops.
current_head="$(jq -r .head "$out/pull-request.json")"
if [[ "$current_head" != "$HEAD_SHA" ]]; then
  echo "::error::The head moved from $HEAD_SHA to $current_head; the newer run reviews it." >&2
  exit 1
fi

gh api "repos/$REPOSITORY/pulls/$NUMBER/files?per_page=100" --paginate \
  --jq '.[] | {filename, status, previous_filename, additions, deletions, patch}' \
  | jq -s '.' >"$out/all-files.json"

# Changed paths for the obligations index: every path, including excluded ones.
jq -r '.[] | .filename, (.previous_filename // empty)' "$out/all-files.json" >"$out/changed-paths.txt"
scripts/review-obligations.sh --paths-file "$out/changed-paths.txt" >"$out/obligations.md" 2>&1 \
  || echo "The obligations index failed; review without it." >"$out/obligations.md"

# Drop paths the review never reads, then apply the file ceiling.
jq -c '.[]' "$out/all-files.json" | while IFS= read -r file; do
  path="$(jq -r .filename <<<"$file")"
  if [[ ${#WF_REVIEW_EXCLUDE[@]} -gt 0 ]] && wf_path_matches_any "$path" "${WF_REVIEW_EXCLUDE[@]}"; then
    echo "$path" >>"$out/excluded.txt"
    continue
  fi
  echo "$file"
done | jq -s '.' >"$out/reviewable.json"

total="$(jq length "$out/reviewable.json")"
if [[ "$total" -gt "$MAX_FILES" ]]; then
  echo "Only the first $MAX_FILES of $total reviewable files were collected." >>"$out/truncation.txt"
fi
jq --argjson max "$MAX_FILES" '.[:$max]' "$out/reviewable.json" >"$out/files.json"
rm -f "$out/all-files.json" "$out/reviewable.json"

encode_path() {
  jq -rn --arg path "$1" '$path | split("/") | map(@uri) | join("/")'
}

# Head contents and the head-side lines each patch shows (a review comment may only
# anchor to one of those).
echo '{}' >"$out/lines.json"
jq -c '.[]' "$out/files.json" | while IFS= read -r file; do
  path="$(jq -r .filename <<<"$file")"
  status="$(jq -r .status <<<"$file")"

  if [[ "$status" != removed ]]; then
    mkdir -p "$out/head/$(dirname "$path")"
    if gh api -H 'Accept: application/vnd.github.raw+json' \
      "repos/$REPOSITORY/contents/$(encode_path "$path")?ref=$HEAD_SHA" >"$out/head/$path" 2>/dev/null; then
      if [[ "$(wc -c <"$out/head/$path")" -gt "$MAX_FILE_BYTES" ]]; then
        rm -f "$out/head/$path"
        echo "Head content not collected (over $MAX_FILE_BYTES bytes): $path" >>"$out/truncation.txt"
      fi
    else
      rm -f "$out/head/$path"
      echo "Head content not collected (fetch failed): $path" >>"$out/truncation.txt"
    fi
  fi

  # Each anchorable head-side line with the hunk it belongs to: a multi-line comment
  # must start and end in the same hunk.
  lines="$(jq -r '.patch // ""' <<<"$file" | awk '
    /^@@/ { hunk++; match($0, /\+[0-9]+/); line = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
    /^\+/ || /^ / { print line, hunk; line++; next }
    /^-/ { next }
  ' | jq -Rn '[inputs | split(" ") | {line: (.[0] | tonumber), hunk: (.[1] | tonumber)}]')"
  jq --arg path "$path" --argjson lines "$lines" '.[$path] = $lines' "$out/lines.json" >"$out/lines.tmp"
  mv "$out/lines.tmp" "$out/lines.json"
done

# Earlier AI reviews (recognised by their marker) and the conversation around them.
gh api "repos/$REPOSITORY/pulls/$NUMBER/reviews?per_page=100" --paginate \
  --jq '.[] | select(.user.type == "Bot" and (.body | test("<!-- ai-review: "))) | {state, commit_id, submitted_at, body}' \
  | jq -s '.' >"$out/reviews.json"

gh api "repos/$REPOSITORY/pulls/$NUMBER/comments?per_page=100" --paginate \
  --jq '.[] | {id, in_reply_to_id, path, line, author: .user.login, body}' \
  | jq -s --argjson max "$MAX_COMMENTS" --argjson chars "$MAX_COMMENT_CHARS" \
    '.[-$max:] | map(.body |= .[:$chars])' >"$out/review-comments.json"

gh api "repos/$REPOSITORY/issues/$NUMBER/comments?per_page=100" --paginate \
  --jq '.[] | {author: .user.login, created_at, body}' \
  | jq -s --argjson max "$MAX_COMMENTS" --argjson chars "$MAX_COMMENT_CHARS" \
    '.[-$max:] | map(.body |= .[:$chars])' >"$out/issue-comments.json"

echo "Collected $(jq length "$out/files.json") file(s) for review."

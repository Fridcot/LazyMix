#!/usr/bin/env bash
# Builds the review prompt from prompt.md and rubrics.md and prints it. Shared by the AI
# review workflow and the evaluation runner (evals/ai-review/run.sh in agentic-workflow),
# so both review with exactly the same text. Fails on any placeholder left unsubstituted.
#
# Environment: NUMBER, REPOSITORY, POSTURE (full|settling), INPUT_DIR (default
#              .ai-review-input)
set -euo pipefail

: "${NUMBER:?}" "${REPOSITORY:?}" "${POSTURE:?}"
input_dir="${INPUT_DIR:-.ai-review-input}"
here="$(dirname "${BASH_SOURCE[0]}")"

if [[ "$POSTURE" == settling ]]; then
  posture_text="This pull request has already had several automatic reviews. Report P1 findings only."
else
  posture_text="Full review: report P1, P2 and P3 findings."
fi
# Replacements are quoted: since bash 5.2 an unquoted "&" in one inserts the match.
prompt="$(cat "$here/prompt.md")"
rubrics="$(cat "$here/rubrics.md")"
prompt="${prompt//'{{NUMBER}}'/"$NUMBER"}"
prompt="${prompt//'{{REPOSITORY}}'/"$REPOSITORY"}"
prompt="${prompt//'{{INPUT_DIR}}'/"$input_dir"}"
prompt="${prompt//'{{POSTURE_TEXT}}'/"$posture_text"}"
prompt="${prompt//'{{POSTURE}}'/"$POSTURE"}"
prompt="${prompt//'{{RUBRICS}}'/"$rubrics"}"
if grep -q '{{[A-Z_]*}}' <<<"$prompt"; then
  echo "::error::Unsubstituted placeholder in the prompt." >&2
  exit 1
fi
printf '%s\n' "$prompt"

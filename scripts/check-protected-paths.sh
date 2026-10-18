#!/usr/bin/env bash
# Reads changed paths from standard input (a rename lists both its old and new path)
# and prints the ones WF_PROTECTED_PATHS covers. Exit status 0 either way; the caller
# decides what a protected path means for the author.
set -euo pipefail

# shellcheck source=lib/workflow.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/workflow.sh"

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  if [[ ${#WF_PROTECTED_PATHS[@]} -gt 0 ]] && wf_path_matches_any "$path" "${WF_PROTECTED_PATHS[@]}"; then
    echo "$path"
  fi
done | sort -u

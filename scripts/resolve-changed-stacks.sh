#!/usr/bin/env bash
# Decides which stacks a change reaches. The local gates and CI both call this script,
# so the path lists in scripts/workflow.conf are the only place a stack is defined.
#
# Usage:
#   resolve-changed-stacks.sh                  # paths changed against the base, plus the working tree
#   resolve-changed-stacks.sh --base <ref>     # paths in <ref>...HEAD (CI)
#   resolve-changed-stacks.sh --stdin          # paths read from standard input
#   resolve-changed-stacks.sh --all            # every configured stack (CI fallback)
#   add --github-output to also append the result to $GITHUB_OUTPUT
set -euo pipefail

# shellcheck source=lib/workflow.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/workflow.sh"

mode=worktree
base=""
github_output=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) mode=base base="$2"; shift 2 ;;
    --stdin) mode=stdin; shift ;;
    --all) mode=all; shift ;;
    --github-output) github_output=true; shift ;;
    *) wf_fail "unknown argument: $1" ;;
  esac
done

dotnet=false
frontend=false
custom=false

if [[ "$mode" == all ]]; then
  if [[ -n "$WF_DOTNET_SOLUTION" ]]; then dotnet=true; fi
  if [[ -n "$WF_FRONTEND_DIR" ]]; then frontend=true; fi
  if wf_custom_enabled; then custom=true; fi
else
  case "$mode" in
    worktree) paths="$(wf_changed_paths)" ;;
    base) paths="$(git diff --name-only --no-renames "$base...HEAD")" ;;
    stdin) paths="$(cat)" ;;
  esac
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if wf_path_matches_any "$path" "${WF_ALL_STACKS_PATHS[@]}"; then
      if [[ -n "$WF_DOTNET_SOLUTION" ]]; then dotnet=true; fi
      if [[ -n "$WF_FRONTEND_DIR" ]]; then frontend=true; fi
      if wf_custom_enabled; then custom=true; fi
    fi
    if wf_is_dotnet_path "$path"; then dotnet=true; fi
    if wf_is_frontend_path "$path"; then frontend=true; fi
    if wf_is_custom_path "$path"; then custom=true; fi
  done <<<"$paths"
fi

result="$(printf 'dotnet=%s\nfrontend=%s\ncustom=%s\n' "$dotnet" "$frontend" "$custom")"
echo "$result"

if [[ "$github_output" == true ]]; then
  echo "$result" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
fi

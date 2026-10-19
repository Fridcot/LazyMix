#!/usr/bin/env bash
# Workspace preflight. Prints one "Key: value" line per fact. Without --fetch it changes
# nothing, so "Contains base branch" is against the last fetched base.
#
# Usage: inspect-workspace.sh [--fetch]
#   --fetch  first fetch WF_BASE_BRANCH into its tracking ref the way the gates do (the
#            only write it makes); "Base fetch" reports the outcome
set -euo pipefail

# shellcheck source=lib/workflow.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/workflow.sh"

fetch=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fetch) fetch=true; shift ;;
    *) wf_fail "unknown argument: $1 (usage: inspect-workspace.sh [--fetch])" ;;
  esac
done

cd "$WF_ROOT"

fetched="not requested"
if [[ "$fetch" == true ]]; then
  remote="$(wf_base_remote)"
  if [[ -z "$remote" ]]; then
    fetched="skipped (no base remote resolves)"
  elif wf_fetch_base "$remote"; then
    fetched="$remote/$WF_BASE_BRANCH"
  else
    fetched="failed ($remote/$WF_BASE_BRANCH)"
  fi
fi

branch="$(wf_current_branch)"

if [[ "$(git rev-parse --path-format=absolute --git-dir)" == "$(git rev-parse --path-format=absolute --git-common-dir)" ]]; then
  worktree="primary checkout"
else
  worktree="linked worktree"
fi

upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo none)"
base="$(wf_base_ref)"

if [[ -z "$base" ]]; then
  contains=unknown
elif git merge-base --is-ancestor "$base" HEAD 2>/dev/null; then
  contains=yes
else
  contains=no
fi

dirty="$(git status --porcelain=v1 --untracked-files=all -- . ':(exclude)artifacts/verify' | wc -l | tr -d ' ')"
if [[ "$dirty" == 0 ]]; then
  tree=clean
else
  tree="dirty ($dirty paths)"
fi

if [[ "$branch" == "$WF_BASE_BRANCH" || "$branch" == main || "$branch" == master ]]; then
  branch_kind="base branch (do not edit here)"
elif [[ "$branch" == "$WF_AGENT_BRANCH_PREFIX"* ]]; then
  branch_kind="agent branch"
elif [[ "$branch" == worktree-* ]]; then
  branch_kind="harness scratch branch (rename to ${WF_AGENT_BRANCH_PREFIX}<short-description>)"
else
  branch_kind="other"
fi

if command -v dotnet >/dev/null 2>&1; then
  sdk="$(dotnet --version 2>/dev/null || echo unavailable)"
else
  sdk="not installed"
fi

printf 'Repository: %s\n' "$WF_ROOT"
printf 'Branch: %s\n' "$branch"
printf 'Branch kind: %s\n' "$branch_kind"
printf 'Worktree: %s\n' "$worktree"
printf 'Upstream: %s\n' "$upstream"
printf 'Base fetch: %s\n' "$fetched"
printf 'Base branch: %s\n' "${base:-unresolved}"
printf 'Contains base branch: %s\n' "$contains"
printf 'Working tree: %s\n' "$tree"
printf 'Registered worktrees: %s\n' "$(git worktree list | wc -l | tr -d ' ')"
printf '.NET SDK: %s\n' "$sdk"

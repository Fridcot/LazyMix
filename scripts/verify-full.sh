#!/usr/bin/env bash
# The local copy of what CI asserts. Optional: run it when the answer is wanted before
# a push. Every test project, a verifying (never repairing) format pass over the whole
# solution, the frontend build, the custom commands, and the workflow contracts.
#
# Stricter than verify-fast.sh: a base remote is required and untracked files are
# refused, because CI will not see them. Every run appends a line to the run log
# (artifacts/verify/runs.jsonl).
set -euo pipefail

# shellcheck source=lib/workflow.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/workflow.sh"

cd "$WF_ROOT"

wf_run_begin full
trap 'wf_run_end $?' EXIT

wf_run_step base
wf_require_not_base_branch
wf_require_base_contained true

wf_run_step untracked
untracked="$(git ls-files --others --exclude-standard -- . ':(exclude)artifacts/verify')"
if [[ -n "$untracked" ]]; then
  printf '%s\n' "$untracked"
  wf_fail "untracked files would be invisible to CI. Add or remove them first."
fi

wf_run_step record
digest="$(wf_tree_digest)"
if [[ "${VERIFY_FORCE:-0}" != 1 ]] && recorded="$(wf_record_satisfies full "$digest")"; then
  wf_info "This exact tree already passed the full gate at $recorded (VERIFY_FORCE=1 runs anyway)."
  wf_run_skip
  exit 0
fi

wf_run_step stacks
stacks="$(scripts/resolve-changed-stacks.sh)"
wf_run_stacks "$stacks"
wf_step "Stacks reached"
echo "$stacks"

if grep -qx 'dotnet=true' <<<"$stacks"; then
  wf_run_step dotnet
  scripts/run-stack.sh dotnet full
fi

if grep -qx 'frontend=true' <<<"$stacks"; then
  wf_run_step frontend
  scripts/run-stack.sh frontend full
fi

if grep -qx 'custom=true' <<<"$stacks"; then
  wf_run_step custom
  scripts/run-stack.sh custom full
fi

wf_run_step contracts
wf_step "Workflow contracts"
scripts/check-workflow-contracts.sh

wf_run_step whitespace
wf_git_diff_check

wf_record_write full "$digest"
wf_step "verify-full passed"

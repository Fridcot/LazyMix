#!/usr/bin/env bash
# The local gate: run it during implementation and before every commit.
#
# Refuses the base branch, requires the branch to contain the fetched base, runs only
# the stacks the change reaches, narrows .NET tests to the unit suites the change can
# have broken, repairs formatting of the changed files, and records a digest of what
# it verified so an unchanged tree is never verified twice. VERIFY_FORCE=1 ignores
# the record. Every run, skipped ones included, appends a line to the run log
# (artifacts/verify/runs.jsonl).
set -euo pipefail

# shellcheck source=lib/workflow.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/workflow.sh"

cd "$WF_ROOT"

wf_run_begin fast
trap 'wf_run_end $?' EXIT

wf_run_step base
wf_require_not_base_branch
wf_require_base_contained false

wf_run_step record
digest="$(wf_tree_digest)"
if [[ "${VERIFY_FORCE:-0}" != 1 ]] && recorded="$(wf_record_satisfies fast "$digest")"; then
  wf_info "This exact tree already passed at $recorded. Nothing to re-verify (VERIFY_FORCE=1 runs anyway)."
  wf_run_skip
  exit 0
fi

wf_run_step stacks
changed="$(wf_changed_paths)"
stacks="$(scripts/resolve-changed-stacks.sh --stdin <<<"$changed")"
wf_run_stacks "$stacks"
wf_step "Stacks reached"
echo "$stacks"

work="$(mktemp -d)"
trap 'status=$?; rm -rf "$work"; wf_run_end "$status"' EXIT

if grep -qx 'dotnet=true' <<<"$stacks"; then
  wf_run_step dotnet
  scripts/resolve-changed-unit-suites.sh <<<"$changed" >"$work/suites"
  wf_run_suites "$work/suites"
  : >"$work/format-files"
  while IFS= read -r path; do
    if [[ "$path" == *.cs && -f "$path" ]] && wf_is_dotnet_path "$path"; then
      echo "$path" >>"$work/format-files"
    fi
  done <<<"$changed"
  WF_SUITES_FILE="$work/suites" WF_FORMAT_FILES_FILE="$work/format-files" scripts/run-stack.sh dotnet fast
fi

if grep -qx 'frontend=true' <<<"$stacks"; then
  wf_run_step frontend
  scripts/run-stack.sh frontend fast
fi

if grep -qx 'custom=true' <<<"$stacks"; then
  wf_run_step custom
  scripts/run-stack.sh custom fast
fi

if ! grep -q '=true' <<<"$stacks"; then
  wf_info "The change reaches no build; nothing to compile or test."
fi

wf_run_step whitespace
wf_git_diff_check

wf_run_step rewrite
after="$(wf_tree_digest)"
if [[ "$after" != "$digest" ]]; then
  wf_step "The gate changed the tree"
  git status --short
  wf_fail "the formatter (or a custom command) changed the tree. Review the changes and rerun; nothing was recorded."
fi

wf_record_write fast "$digest"
wf_step "verify-fast passed"

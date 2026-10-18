#!/usr/bin/env bash
# Builds and tests one stack. The single implementation behind verify-fast.sh,
# verify-full.sh and the CI jobs, so a command cannot differ between them.
#
# Usage: run-stack.sh <dotnet|frontend|custom> <fast|full|ci>
#
#   fast  restore, Release build, the unit suites listed in $WF_SUITES_FILE, and a
#         repairing format pass over the .cs files listed in $WF_FORMAT_FILES_FILE
#   full  restore, Release build, every test (or every unit suite when
#         WF_FULL_RUNS_ALL_TESTS=false), and a verifying format pass
#   ci    the same as full
#
# The custom stack runs each of WF_CUSTOM_COMMANDS (bash -c, from the repository root)
# in every mode: a project's own suite when it has no .NET or frontend stack, or beside them.
set -euo pipefail

# shellcheck source=lib/workflow.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/workflow.sh"

stack="${1:?usage: run-stack.sh <dotnet|frontend|custom> <fast|full|ci>}"
mode="${2:?usage: run-stack.sh <dotnet|frontend|custom> <fast|full|ci>}"
[[ "$mode" == fast || "$mode" == full || "$mode" == ci ]] || wf_fail "unknown mode: $mode"

cd "$WF_ROOT"

# .NET 10 selects the test platform in global.json; the two take different arguments.
uses_testing_platform() {
  [[ -f global.json ]] && grep -q '"Microsoft.Testing.Platform"' global.json
}

dotnet_test_project() {
  if uses_testing_platform; then
    dotnet test --project "$1" -c Release --no-build
  else
    dotnet test "$1" -c Release --no-build
  fi
}

dotnet_test_solution() {
  if uses_testing_platform; then
    dotnet test --solution "$WF_DOTNET_SOLUTION" -c Release --no-build
  else
    dotnet test "$WF_DOTNET_SOLUTION" -c Release --no-build
  fi
}

run_dotnet() {
  [[ -n "$WF_DOTNET_SOLUTION" ]] || wf_fail "WF_DOTNET_SOLUTION is not configured."

  if [[ -f .config/dotnet-tools.json ]]; then
    wf_step "dotnet tool restore"
    dotnet tool restore
  fi

  wf_step "dotnet restore"
  if git ls-files --error-unmatch '*packages.lock.json' >/dev/null 2>&1; then
    dotnet restore "$WF_DOTNET_SOLUTION" --locked-mode
  else
    dotnet restore "$WF_DOTNET_SOLUTION"
  fi

  wf_step "dotnet build (Release)"
  dotnet build "$WF_DOTNET_SOLUTION" -c Release --no-restore

  if [[ "$mode" == fast ]]; then
    local suite count=0
    if [[ -n "${WF_SUITES_FILE:-}" && -s "$WF_SUITES_FILE" ]]; then
      while IFS= read -r suite; do
        [[ -n "$suite" ]] || continue
        wf_step "dotnet test $suite"
        dotnet_test_project "$suite"
        count=$((count + 1))
      done <"$WF_SUITES_FILE"
    fi
    [[ $count -gt 0 ]] || wf_info "No unit suite to run for this change."

    if [[ -n "${WF_FORMAT_FILES_FILE:-}" && -s "$WF_FORMAT_FILES_FILE" ]]; then
      wf_step "dotnet format (repairing the changed files)"
      local -a files=()
      mapfile -t files <"$WF_FORMAT_FILES_FILE"
      dotnet format "$WF_DOTNET_SOLUTION" --no-restore --include "${files[@]}"
    fi
  else
    if [[ "$WF_FULL_RUNS_ALL_TESTS" == true ]]; then
      wf_step "dotnet test (every test project)"
      dotnet_test_solution
    else
      local pattern suite
      local -a matches
      shopt -s nullglob
      for pattern in "${WF_UNIT_TEST_PROJECTS[@]}"; do
        # shellcheck disable=SC2206
        matches=($pattern)
        for suite in "${matches[@]}"; do
          wf_step "dotnet test $suite"
          dotnet_test_project "$suite"
        done
      done
      shopt -u nullglob
    fi

    wf_step "dotnet format --verify-no-changes"
    dotnet format "$WF_DOTNET_SOLUTION" --no-restore --verify-no-changes
  fi
}

# 0: defined, 1: not defined; anything else (unreadable or invalid package.json) fails
# the gate rather than skipping every script.
has_script() {
  local status=0
  jq -e --arg name "$1" '.scripts[$name] != null' package.json >/dev/null || status=$?
  if [[ $status -gt 1 ]]; then
    wf_fail "could not read $WF_FRONTEND_DIR/package.json (jq exit $status)."
  fi
  return "$status"
}

run_frontend() {
  [[ -n "$WF_FRONTEND_DIR" ]] || wf_fail "WF_FRONTEND_DIR is not configured."
  wf_require_jq
  cd "$WF_FRONTEND_DIR"

  wf_step "$WF_FRONTEND_PM install (locked)"
  case "$WF_FRONTEND_PM" in
    npm) npm ci ;;
    pnpm) pnpm install --frozen-lockfile ;;
    *) wf_fail "unsupported WF_FRONTEND_PM: $WF_FRONTEND_PM" ;;
  esac

  local -a scripts
  if [[ "$mode" == fast ]]; then
    scripts=("${WF_FRONTEND_FAST_SCRIPTS[@]}")
    has_script format && scripts+=(format)
  else
    scripts=("${WF_FRONTEND_FULL_SCRIPTS[@]}")
    has_script format:check && scripts+=(format:check)
  fi

  local script
  for script in "${scripts[@]}"; do
    if has_script "$script"; then
      wf_step "$WF_FRONTEND_PM run $script"
      if [[ "$script" == test && "$WF_FRONTEND_PM" == npm ]]; then
        # Keep a watch-mode test runner from waiting for input.
        CI=true npm run test
      else
        CI=true "$WF_FRONTEND_PM" run "$script"
      fi
    else
      wf_info "Skipped '$script': package.json defines no such script."
    fi
  done
}

run_custom() {
  wf_custom_enabled || wf_fail "WF_CUSTOM_COMMANDS is not configured."
  local command
  for command in "${WF_CUSTOM_COMMANDS[@]}"; do
    wf_step "$command"
    bash -c "$command"
  done
}

case "$stack" in
  dotnet) run_dotnet ;;
  frontend) run_frontend ;;
  custom) run_custom ;;
  *) wf_fail "unknown stack: $stack" ;;
esac

# Shared helpers for the workflow scripts. Sourced, never executed.
# shellcheck shell=bash

# Print non-ASCII paths verbatim (git C-quotes them by default, and a quoted path matches
# no pattern). Applies to every git call of every script that sources this file.
# Appended to any configuration already passed through the environment, and only once
# when scripts source this file from each other.
if ! env | grep -q '^GIT_CONFIG_KEY_[0-9]*=core.quotePath$'; then
  wf_config_index="${GIT_CONFIG_COUNT:-0}"
  export "GIT_CONFIG_KEY_$wf_config_index=core.quotePath" "GIT_CONFIG_VALUE_$wf_config_index=false"
  export GIT_CONFIG_COUNT=$((wf_config_index + 1))
fi

WF_ROOT="$(git rev-parse --show-toplevel)"
WF_CONFIG="${WF_CONFIG:-$WF_ROOT/scripts/workflow.conf}"

# Defaults, overridden by the configuration file.
WF_BASE_BRANCH=main
WF_BASE_REPOSITORY=""
WF_AGENT_BRANCH_PREFIX="agent/"
WF_DOTNET_SOLUTION=""
WF_DOTNET_PATHS=()
WF_DOTNET_EXCLUDE=()
WF_ALL_STACKS_PATHS=(scripts/ .github/workflows/ci.yml)
WF_SHARED_BUILD_INPUTS=()
WF_UNIT_TEST_PROJECTS=()
WF_FULL_RUNS_ALL_TESTS=true
WF_TEST_ROOTS=(tests/)
WF_FRONTEND_DIR=""
WF_FRONTEND_PM=npm
WF_FRONTEND_PATHS=()
WF_FRONTEND_FAST_SCRIPTS=(lint typecheck test)
WF_FRONTEND_FULL_SCRIPTS=(lint typecheck test build)
WF_CUSTOM_PATHS=()
WF_CUSTOM_COMMANDS=()
WF_DOCS_ROOTS=(docs/)
WF_REGISTER_RULES=()
WF_PROTECTED_PATHS=()
WF_ALLOWED_ACTION_OWNERS=(actions github)
WF_PULL_REQUEST_TARGET_WORKFLOWS=()
WF_REVIEW_EXCLUDE=()
WF_RETRO_REPOSITORIES=()

if [[ -f "$WF_CONFIG" ]]; then
  # shellcheck source=/dev/null
  source "$WF_CONFIG"
fi

if [[ -n "$WF_FRONTEND_DIR" && ${#WF_FRONTEND_PATHS[@]} -eq 0 ]]; then
  WF_FRONTEND_PATHS=("${WF_FRONTEND_DIR%/}/")
fi

WF_RECORD_DIR="$WF_ROOT/artifacts/verify"

# Called by the scripts that read JSON; the others (inspect-workspace.sh) work without jq.
wf_require_jq() {
  command -v jq >/dev/null 2>&1 || wf_fail "jq is required (sudo apt install jq)."
}

wf_info() { printf '%s\n' "$*"; }
wf_step() { printf '\n==> %s\n' "$*"; }
wf_fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# wf_path_matches <path> <pattern>
# "dir/" is a prefix, a pattern with * or ? is a shell glob (where * also spans /),
# anything else is an exact path.
wf_path_matches() {
  local path="$1" pattern="$2"
  if [[ "$pattern" == */ ]]; then
    [[ "$path" == "$pattern"* ]]
  elif [[ "$pattern" == *[\*\?]* ]]; then
    # shellcheck disable=SC2053
    [[ "$path" == $pattern ]]
  else
    [[ "$path" == "$pattern" ]]
  fi
}

# wf_path_matches_any <path> <pattern>...
wf_path_matches_any() {
  local path="$1" pattern
  shift
  for pattern in "$@"; do
    if wf_path_matches "$path" "$pattern"; then
      return 0
    fi
  done
  return 1
}

wf_is_dotnet_path() {
  [[ -n "$WF_DOTNET_SOLUTION" ]] || return 1
  wf_path_matches_any "$1" "${WF_DOTNET_PATHS[@]}" || return 1
  if [[ ${#WF_DOTNET_EXCLUDE[@]} -gt 0 ]] && wf_path_matches_any "$1" "${WF_DOTNET_EXCLUDE[@]}"; then
    return 1
  fi
  return 0
}

wf_custom_enabled() {
  [[ ${#WF_CUSTOM_COMMANDS[@]} -gt 0 ]]
}

wf_is_custom_path() {
  wf_custom_enabled || return 1
  [[ ${#WF_CUSTOM_PATHS[@]} -gt 0 ]] || return 1
  wf_path_matches_any "$1" "${WF_CUSTOM_PATHS[@]}"
}

wf_is_frontend_path() {
  [[ -n "$WF_FRONTEND_DIR" ]] || return 1
  wf_path_matches_any "$1" "${WF_FRONTEND_PATHS[@]}"
}

# wf_glob_to_regex <git-style glob>
# Converts a `describes:` glob into an extended regular expression: `**/` matches
# zero or more directories, `**` anything, `*` and `?` stay within one path segment.
wf_glob_to_regex() {
  local glob="$1" regex="" i char next
  for ((i = 0; i < ${#glob}; i++)); do
    char="${glob:i:1}"
    next="${glob:i+1:1}"
    if [[ "$char" == "*" && "$next" == "*" ]]; then
      if [[ "${glob:i+2:1}" == "/" ]]; then
        regex+="(.*/)?"
        ((i += 2))
      else
        regex+=".*"
        ((i += 1))
      fi
    elif [[ "$char" == "*" ]]; then
      regex+="[^/]*"
    elif [[ "$char" == "?" ]]; then
      regex+="[^/]"
    else
      case "$char" in
        . | '[' | ']' | '^' | '$' | '(' | ')' | '+' | '{' | '}' | '|' | '\') regex+="\\$char" ;;
        *) regex+="$char" ;;
      esac
    fi
  done
  # A literal path also covers everything beneath it, as a git pathspec does; a glob
  # matches exactly what it says.
  if [[ "$glob" == *[\*\?]* && "$glob" != */ ]]; then
    printf '^%s$' "$regex"
  else
    printf '^%s(/.*)?$' "${regex%/}"
  fi
}

# ---------------------------------------------------------------------------------
# Base branch
# ---------------------------------------------------------------------------------

wf_current_branch() {
  git symbolic-ref --quiet --short HEAD 2>/dev/null || echo "(detached)"
}

# Prints the remote the base branch is read from, or nothing when none resolves.
# With WF_BASE_REPOSITORY set, the remote is chosen by URL (upstream first, then
# origin, then any other), so a fork resolves against the repository it merges into.
wf_base_remote() {
  local remote url candidates
  candidates="$(git remote)"
  [[ -n "$candidates" ]] || return 0
  if [[ -z "$WF_BASE_REPOSITORY" ]]; then
    if grep -qx origin <<<"$candidates"; then
      echo origin
    fi
    return 0
  fi
  for remote in upstream origin $candidates; do
    grep -qx "$remote" <<<"$candidates" || continue
    url="$(git remote get-url "$remote" 2>/dev/null || true)"
    url="${url%.git}"
    if [[ "$url" == *[:/]"$WF_BASE_REPOSITORY" ]]; then
      echo "$remote"
      return 0
    fi
  done
  return 0
}

# Prints the ref the branch is compared against: <remote>/<base>, else the local
# base branch, else nothing.
wf_base_ref() {
  local remote
  remote="$(wf_base_remote)"
  if [[ -n "$remote" ]] && git rev-parse --verify --quiet "refs/remotes/$remote/$WF_BASE_BRANCH" >/dev/null; then
    echo "$remote/$WF_BASE_BRANCH"
  elif git rev-parse --verify --quiet "refs/heads/$WF_BASE_BRANCH" >/dev/null; then
    echo "$WF_BASE_BRANCH"
  fi
}

wf_require_not_base_branch() {
  local branch
  branch="$(wf_current_branch)"
  if [[ "$branch" == "$WF_BASE_BRANCH" || "$branch" == main || "$branch" == master ]]; then
    wf_fail "refusing to run on '$branch'. Check out the branch that carries the change."
  fi
}

# wf_require_base_contained <required: true|false>
# Fetches the base branch into its tracking ref (an explicit destination refspec, so a
# stale tracking ref cannot hide remote movement) and requires HEAD to contain it.
# A checkout with no base remote fails when required and continues otherwise.
wf_require_base_contained() {
  local required="$1" remote
  remote="$(wf_base_remote)"
  if [[ -z "$remote" ]]; then
    if [[ "$required" == true ]]; then
      wf_fail "no base remote resolves${WF_BASE_REPOSITORY:+ for $WF_BASE_REPOSITORY}; add it and fetch $WF_BASE_BRANCH."
    fi
    wf_info "No base remote resolves; skipping the base check."
    return 0
  fi
  if ! git fetch --quiet "$remote" "+refs/heads/$WF_BASE_BRANCH:refs/remotes/$remote/$WF_BASE_BRANCH"; then
    wf_fail "could not fetch $remote/$WF_BASE_BRANCH. An unreachable base is a blocked gate, not a pass."
  fi
  if ! git merge-base --is-ancestor "$remote/$WF_BASE_BRANCH" HEAD; then
    wf_fail "the branch does not contain $remote/$WF_BASE_BRANCH. Rebase it onto the fetched base and rerun."
  fi
  wf_info "Branch contains $remote/$WF_BASE_BRANCH."
}

# Every path the change reaches: committed since the base, staged, unstaged and
# untracked. Renames are listed as both paths, deletions are included.
wf_changed_paths() {
  local base
  base="$(wf_base_ref)"
  {
    if [[ -n "$base" ]]; then
      git diff --name-only --no-renames "$base...HEAD"
    fi
    git diff --name-only --no-renames HEAD
    git ls-files --others --exclude-standard
  } | { grep -v '^artifacts/verify/' || true; } | sort -u
}

# ---------------------------------------------------------------------------------
# Verification records
# ---------------------------------------------------------------------------------

# A digest of exactly what a gate verified: the commit, the working tree (tracked
# and untracked content) and the gate scripts themselves. The base is excluded on
# purpose; every run re-checks it.
wf_tree_digest() {
  (
    cd "$WF_ROOT"
    git rev-parse HEAD
    git status --porcelain=v1 --untracked-files=all -- . ':(exclude)artifacts/verify'
    git diff HEAD --binary --no-ext-diff --no-textconv --no-color
    git ls-files --others --exclude-standard -z -- ':(exclude)artifacts/verify' | xargs -0 -r sha256sum
    find scripts -type f \( -name '*.sh' -o -name 'workflow.conf' \) | sort | xargs -r sha256sum
  ) | sha256sum | cut -d' ' -f1
}

# wf_record_satisfies <gate> <digest>: prints the recorded time when a passing run of
# this gate (or of a stronger one) already verified exactly this digest.
wf_record_satisfies() {
  local gate="$1" digest="$2" candidate file
  local -a accepted=("$gate")
  [[ "$gate" == fast ]] && accepted+=(full)
  for candidate in "${accepted[@]}"; do
    file="$WF_RECORD_DIR/$candidate.digest"
    if [[ -f "$file" && "$(sed -n 1p "$file")" == "$digest" ]]; then
      printf '%s (%s gate)\n' "$(sed -n 2p "$file")" "$candidate"
      return 0
    fi
  done
  return 1
}

wf_record_write() {
  local gate="$1" digest="$2"
  mkdir -p "$WF_RECORD_DIR"
  printf '%s\n%s\n' "$digest" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$WF_RECORD_DIR/$gate.digest"
}

wf_git_diff_check() {
  local base
  base="$(wf_base_ref)"
  wf_step "Whitespace check"
  if [[ -n "$base" ]]; then
    git diff --check "$base...HEAD" || wf_fail "whitespace errors in commits since $base (listed above)."
  fi
  git diff --check --cached || wf_fail "whitespace errors in staged changes (listed above)."
  git diff --check || wf_fail "whitespace errors in unstaged changes (listed above)."
}

# ---------------------------------------------------------------------------------
# Run log
# ---------------------------------------------------------------------------------

# Every gate run appends one JSON line to artifacts/verify/runs.jsonl: the stacks and
# suites it reached, how long each step took and how it ended. The log is evidence for
# improving the workflow, never an input to a gate, so it never fails one: without jq,
# or when the line cannot be written, the run goes unlogged.
#
# A gate calls wf_run_begin, then wf_run_step <name> at the start of each step (which
# ends the previous one), and installs `trap 'wf_run_end $?' EXIT`, so a step that
# fails through errexit or wf_fail is still recorded as the failed step.
WF_RUN_LOG="$WF_RECORD_DIR/runs.jsonl"

# Seconds since the epoch, with microseconds where bash provides them (5.0+).
wf_now() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    printf '%s' "${EPOCHREALTIME/,/.}"
  else
    date +%s
  fi
}

wf_elapsed() {
  awk -v from="$1" -v to="$(wf_now)" 'BEGIN { printf "%.3f", to - from }'
}

wf_run_begin() {
  WF_RUN_GATE="$1"
  WF_RUN_STARTED="$(wf_now)"
  WF_RUN_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  WF_RUN_STEPS=""
  WF_RUN_STEP=""
  WF_RUN_STEP_STARTED=""
  WF_RUN_SKIPPED=false
  WF_RUN_STACKS=""
  WF_RUN_SUITES=""
  WF_RUN_HAS_SUITES=false
}

# Ends the running step as passed and starts the next one.
wf_run_step() {
  if [[ -n "$WF_RUN_STEP" ]]; then
    WF_RUN_STEPS+="$WF_RUN_STEP"$'\t'"$(wf_elapsed "$WF_RUN_STEP_STARTED")"$'\tpass\n'
  fi
  WF_RUN_STEP="$1"
  WF_RUN_STEP_STARTED="$(wf_now)"
}

# The run stopped because its record already covers this tree.
wf_run_skip() { WF_RUN_SKIPPED=true; }

# wf_run_stacks <resolve-changed-stacks output>
wf_run_stacks() { WF_RUN_STACKS="$1"; }

# wf_run_suites <file listing the unit suites, one per line>
wf_run_suites() {
  WF_RUN_HAS_SUITES=true
  WF_RUN_SUITES="$(cat "$1" 2>/dev/null || true)"
}

# wf_run_end <exit status>: appends the run's line. Called from the EXIT trap.
wf_run_end() {
  local status="$1" result=pass failed="" head branch
  [[ -n "${WF_RUN_GATE:-}" ]] || return 0
  if [[ -n "$WF_RUN_STEP" ]]; then
    if [[ "$status" -eq 0 ]]; then
      WF_RUN_STEPS+="$WF_RUN_STEP"$'\t'"$(wf_elapsed "$WF_RUN_STEP_STARTED")"$'\tpass\n'
    else
      WF_RUN_STEPS+="$WF_RUN_STEP"$'\t'"$(wf_elapsed "$WF_RUN_STEP_STARTED")"$'\tfail\n'
      failed="$WF_RUN_STEP"
    fi
  fi
  if [[ "$status" -ne 0 ]]; then
    result=fail
  elif [[ "$WF_RUN_SKIPPED" == true ]]; then
    result=skipped
  fi
  command -v jq >/dev/null 2>&1 || return 0
  head="$(git rev-parse HEAD 2>/dev/null || true)"
  branch="$(wf_current_branch)"
  mkdir -p "$WF_RECORD_DIR" 2>/dev/null || return 0
  jq -cn \
    --arg gate "$WF_RUN_GATE" \
    --arg started_at "$WF_RUN_STARTED_AT" \
    --arg head "$head" \
    --arg branch "$branch" \
    --arg result "$result" \
    --argjson exit_code "$status" \
    --argjson duration "$(wf_elapsed "$WF_RUN_STARTED")" \
    --arg stacks "$WF_RUN_STACKS" \
    --arg suites "$WF_RUN_SUITES" \
    --argjson has_suites "$WF_RUN_HAS_SUITES" \
    --arg steps "$WF_RUN_STEPS" \
    --arg failed "$failed" '
    def lines: split("\n") | map(select(length > 0));
    {
      schema: 1,
      gate: $gate,
      started_at: $started_at,
      head: $head,
      branch: $branch,
      result: $result,
      skipped_by_record: ($result == "skipped"),
      exit_code: $exit_code,
      duration_seconds: $duration,
      stacks: (if $stacks == "" then null
               else $stacks | lines | map(split("=") | {(.[0]): (.[1] == "true")}) | add end),
      suites: (if $has_suites then $suites | lines else null end),
      steps: ($steps | lines | map(split("\t") | {name: .[0], seconds: (.[1] | tonumber), result: .[2]})),
      failed_step: (if $failed == "" then null else $failed end)
    }' 2>/dev/null >>"$WF_RUN_LOG" || true
}

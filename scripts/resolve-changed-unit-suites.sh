#!/usr/bin/env bash
# Prints the unit test projects a change can have broken, one per line, reading the
# changed paths from standard input. A suite covers its own directory and the
# directory of every project it references directly (ProjectReference Include).
#
# The narrowing is refused, and every unit suite printed, when a changed .NET path
# is a shared build input or maps to no suite: guessing there would skip a suite
# the change did break. CI always runs every suite regardless.
#
# The reason for the choice is written to standard error.
set -euo pipefail

# shellcheck source=lib/workflow.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/workflow.sh"

cd "$WF_ROOT"

mapfile -t suites < <(
  shopt -s nullglob
  for pattern in "${WF_UNIT_TEST_PROJECTS[@]}"; do
    # shellcheck disable=SC2206
    matches=($pattern)
    if [[ ${#matches[@]} -gt 0 ]]; then
      printf '%s\n' "${matches[@]}"
    fi
  done | sort -u
)

if [[ ${#suites[@]} -eq 0 ]]; then
  echo "No unit test project matches WF_UNIT_TEST_PROJECTS." >&2
  exit 0
fi

# suite -> covered directories, as "suite<TAB>dir/" lines.
coverage=""
for suite in "${suites[@]}"; do
  suite_dir="$(dirname "$suite")"
  coverage+="$suite"$'\t'"$suite_dir/"$'\n'
  while IFS= read -r include; do
    [[ -n "$include" ]] || continue
    include="${include//\\//}"
    referenced="$(realpath -m --relative-to="$WF_ROOT" "$WF_ROOT/$suite_dir/$include")"
    coverage+="$suite"$'\t'"$(dirname "$referenced")/"$'\n'
  done < <(grep -o 'ProjectReference Include="[^"]*"' "$suite" | sed 's/.*Include="\([^"]*\)"/\1/')
done

all=false
reason=""
declare -A selected=()

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  wf_is_dotnet_path "$path" || continue
  if [[ ${#WF_SHARED_BUILD_INPUTS[@]} -gt 0 ]] && wf_path_matches_any "$path" "${WF_SHARED_BUILD_INPUTS[@]}"; then
    all=true
    reason="$path is a shared build input"
    break
  fi
  matched=false
  while IFS=$'\t' read -r suite dir; do
    [[ -n "$suite" ]] || continue
    if [[ "$path" == "$dir"* ]]; then
      selected["$suite"]=1
      matched=true
    fi
  done <<<"$coverage"
  # A test-tree path no unit suite covers belongs to a suite only the full gate runs.
  if [[ "$matched" == false ]] && wf_path_matches_any "$path" "${WF_TEST_ROOTS[@]}"; then
    continue
  fi
  if [[ "$matched" == false ]]; then
    all=true
    reason="$path maps to no unit suite"
    break
  fi
done

if [[ "$all" == true ]]; then
  echo "Running every unit suite: $reason." >&2
  printf '%s\n' "${suites[@]}"
  exit 0
fi

if [[ ${#selected[@]} -eq 0 ]]; then
  echo "The change reaches no unit suite." >&2
  exit 0
fi

echo "Running ${#selected[@]} of the ${#suites[@]} unit suites; the rest are left to CI." >&2
printf '%s\n' "${!selected[@]}" | sort

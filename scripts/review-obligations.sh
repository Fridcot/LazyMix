#!/usr/bin/env bash
# Lists what a change obliges elsewhere in the repository: the tests that cover each
# changed source file, the documentation pages whose `describes:` marker covers a
# changed path, and the registers a changed path triggers. Reports, never gates.
#
# Usage:
#   review-obligations.sh                      # the change against the base, plus the working tree
#   review-obligations.sh --paths-file <file>  # an explicit list of changed paths (CI)
set -euo pipefail

# shellcheck source=lib/workflow.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/workflow.sh"

paths_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --paths-file) paths_file="$2"; shift 2 ;;
    *) wf_fail "unknown argument: $1" ;;
  esac
done

if [[ -n "$paths_file" ]]; then
  changed="$(grep -v '^$' "$paths_file" | sort -u || true)"
fi

cd "$WF_ROOT"

if [[ -z "$paths_file" ]]; then
  changed="$(wf_changed_paths)"
fi

if [[ -z "$changed" ]]; then
  echo "No changed paths."
  exit 0
fi

is_changed() { grep -qxF -- "$1" <<<"$changed"; }

echo "## Tests"
echo
tests_reported=false
while IFS= read -r path; do
  if [[ "$path" == *.cs ]] && wf_is_dotnet_path "$path" \
    && ! wf_path_matches_any "$path" "${WF_TEST_ROOTS[@]}" \
    && { [[ ${#WF_REVIEW_EXCLUDE[@]} -eq 0 ]] || ! wf_path_matches_any "$path" "${WF_REVIEW_EXCLUDE[@]}"; }; then
    type="$(basename "$path" .cs)"
    mapfile -t referencing < <(
      for root in "${WF_TEST_ROOTS[@]}"; do
        # Tracked and new (not ignored) files only, so build output under obj/ never counts.
        git ls-files -z --cached --others --exclude-standard -- "${root%/}/*.cs" \
          | xargs -0 -r grep -lw -- "$type" 2>/dev/null || true
      done | sort -u | head -n 20
    )
    tests_reported=true
    if [[ ${#referencing[@]} -eq 0 ]]; then
      echo "- $path: no test references \`$type\`."
    else
      echo "- $path: ${#referencing[@]} test file(s) reference \`$type\`:"
      for test in "${referencing[@]}"; do
        if is_changed "$test"; then mark="changed"; else mark="unchanged"; fi
        echo "    - $test ($mark)"
      done
    fi
  elif wf_is_frontend_path "$path" && [[ "$path" =~ \.(ts|tsx)$ ]] \
    && [[ ! "$path" =~ \.(test|spec)\.tsx?$ && ! "$path" =~ \.d\.ts$ && "$(basename "$path")" != index.ts && ! "$(basename "$path")" =~ \.config\.[cm]?ts$ ]]; then
    stem="${path%.*}"
    sibling=""
    for candidate in "$stem.test.ts" "$stem.test.tsx" "$stem.spec.ts" "$stem.spec.tsx"; do
      if [[ -f "$candidate" ]] || is_changed "$candidate"; then
        sibling="$candidate"
        break
      fi
    done
    tests_reported=true
    if [[ -z "$sibling" ]]; then
      echo "- $path: no sibling test file."
    elif is_changed "$sibling"; then
      echo "- $path: $sibling (changed)"
    else
      echo "- $path: $sibling (unchanged)"
    fi
  fi
done <<<"$changed"
[[ "$tests_reported" == true ]] || echo "No changed source file owes a test."

echo
echo "## Documentation"
echo
docs_reported=false
mapfile -t pages < <(
  for root in "${WF_DOCS_ROOTS[@]}"; do
    if [[ -d "$root" ]]; then find "${root%/}" -type f -name '*.md'; fi
  done | sort -u
)
for page in "${pages[@]}"; do
  marker="$(head -n 15 "$page" | grep -o '<!-- *describes:[^>]*-->' | head -n 1 || true)"
  [[ -n "$marker" ]] || continue
  patterns="$(sed -E 's/<!-- *describes:(.*)-->/\1/' <<<"$marker")"
  matched=()
  IFS=',' read -ra pattern_list <<<"$patterns"
  for pattern in "${pattern_list[@]}"; do
    pattern="$(xargs <<<"$pattern")"
    [[ -n "$pattern" && "$pattern" != none ]] || continue
    regex="$(wf_glob_to_regex "$pattern")"
    while IFS= read -r path; do
      [[ "$path" == "$page" ]] && continue
      if [[ "$path" =~ $regex ]]; then
        matched+=("$path")
      fi
    done <<<"$changed"
  done
  if [[ ${#matched[@]} -gt 0 ]]; then
    docs_reported=true
    if is_changed "$page"; then mark="changed"; else mark="unchanged"; fi
    echo "- $page ($mark) describes:"
    printf '%s\n' "${matched[@]}" | sort -u | sed 's/^/    - /'
  fi
done
[[ "$docs_reported" == true ]] || echo "No page's describes: marker covers a changed path."

echo
echo "## Registers"
echo
registers_reported=false
for rule in "${WF_REGISTER_RULES[@]}"; do
  pattern="${rule%%=>*}"
  register="${rule#*=>}"
  while IFS= read -r path; do
    if wf_path_matches "$path" "$pattern"; then
      registers_reported=true
      if is_changed "$register"; then mark="changed"; else mark="unchanged"; fi
      echo "- $path obliges $register ($mark)"
      break
    fi
  done <<<"$changed"
done
[[ "$registers_reported" == true ]] || echo "No register is triggered."

echo
echo "None of this is a finding. A row becomes one only when it is confirmed in the file it points at."

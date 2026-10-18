#!/usr/bin/env bash
# Contracts the repository's own process files must keep. Runs in CI on every pull
# request and in verify-full.sh. Each contract prints PASS or FAIL with the offending
# paths; the script fails when any contract does.
set -euo pipefail

# shellcheck source=lib/workflow.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/workflow.sh"

cd "$WF_ROOT"

failures=0

# run_contract <name> <function>: the function prints offending items, one per line.
run_contract() {
  local name="$1" output
  output="$("$2")"
  if [[ -z "$output" ]]; then
    printf 'PASS  %s\n' "$name"
  else
    printf 'FAIL  %s\n' "$name"
    sed 's/^/        /' <<<"$output"
    failures=$((failures + 1))
  fi
}

workflow_files() {
  git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml'
}

docs_pages() {
  local root
  for root in "${WF_DOCS_ROOTS[@]}"; do
    git ls-files -- "${root%/}/**.md" "${root%/}/*.md"
  done | sort -u | grep -v -e '-template\.md$' -e '/CLAUDE\.md$' || true
}

claude_md_imports_agents_md() {
  if [[ ! -f CLAUDE.md ]]; then
    echo "CLAUDE.md is missing"
  elif ! grep -qx '@AGENTS.md' CLAUDE.md; then
    echo "CLAUDE.md does not import @AGENTS.md"
  fi
}

# Either .claude/skills links to ../.agents/skills, or (when the project keeps other
# skills there) every skill in .agents/skills has its own link in .claude/skills.
claude_skills_point_at_agents_skills() {
  [[ -d .agents/skills ]] || return 0
  if [[ -L .claude/skills ]]; then
    [[ "$(readlink .claude/skills)" == "../.agents/skills" ]] \
      || echo ".claude/skills links to $(readlink .claude/skills), not ../.agents/skills"
    return 0
  fi
  local skill name
  for skill in .agents/skills/*/; do
    name="$(basename "$skill")"
    if [[ "$(readlink ".claude/skills/$name" 2>/dev/null)" != "../../.agents/skills/$name" ]]; then
      echo ".claude/skills/$name must link to ../../.agents/skills/$name"
    fi
  done
}

every_skill_declares_name_and_description() {
  local skill dir name
  for skill in .agents/skills/*/SKILL.md; do
    [[ -f "$skill" ]] || continue
    dir="$(basename "$(dirname "$skill")")"
    name="$(sed -n '2,10p' "$skill" | sed -n 's/^name: *//p' | head -n 1)"
    if [[ "$(head -n 1 "$skill")" != "---" ]]; then
      echo "$skill: no frontmatter"
    elif [[ "$name" != "$dir" ]]; then
      echo "$skill: name '$name' does not match directory '$dir'"
    elif ! sed -n '2,10p' "$skill" | grep -q '^description: .\+'; then
      echo "$skill: no description"
    fi
  done
}

every_docs_page_declares_what_it_describes() {
  local page
  while IFS= read -r page; do
    [[ -n "$page" ]] || continue
    if ! head -n 15 "$page" | grep -q '<!-- *describes:[^>]*-->'; then
      echo "$page"
    fi
  done < <(docs_pages)
}

every_describes_pattern_matches_something() {
  local page marker patterns pattern
  while IFS= read -r page; do
    [[ -n "$page" ]] || continue
    marker="$(head -n 15 "$page" | grep -o '<!-- *describes:[^>]*-->' | head -n 1 || true)"
    [[ -n "$marker" ]] || continue
    patterns="$(sed -E 's/<!-- *describes:(.*)-->/\1/' <<<"$marker")"
    IFS=',' read -ra list <<<"$patterns"
    for pattern in "${list[@]}"; do
      pattern="$(xargs <<<"$pattern")"
      [[ -n "$pattern" && "$pattern" != none ]] || continue
      if [[ -z "$(git ls-files -- ":(glob)$pattern" | head -n 1)" ]]; then
        echo "$page: '$pattern' matches no tracked file"
      fi
    done
  done < <(docs_pages)
}

# Top-level jobs sit at two spaces of indentation under `jobs:`; each must declare
# `permissions:` at four.
every_workflow_job_declares_permissions() {
  local file
  while IFS= read -r file; do
    awk -v file="$file" '
      /^jobs:/ { in_jobs = 1; next }
      in_jobs && /^[^ #]/ { in_jobs = 0 }
      in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
        if (job != "" && !has) print file ": job " job " declares no permissions"
        job = $1; sub(":", "", job); has = 0; next
      }
      in_jobs && /^    permissions:/ { has = 1 }
      END { if (job != "" && !has) print file ": job " job " declares no permissions" }
    ' "$file"
  done < <(workflow_files)
}

every_checkout_disables_persisted_credentials() {
  local file
  while IFS= read -r file; do
    awk -v file="$file" '
      /uses: actions\/checkout@/ { pending = NR; indent = index($0, "uses:"); next }
      pending && /persist-credentials: *false/ { pending = 0; next }
      pending && /^[[:space:]]*- / && index($0, "-") < indent { print file ":" pending ": checkout keeps credentials"; pending = 0 }
      END { if (pending) print file ":" pending ": checkout keeps credentials" }
    ' "$file"
  done < <(workflow_files)
}

every_action_comes_from_an_allowed_owner() {
  local file line owner
  while IFS= read -r file; do
    while IFS= read -r line; do
      owner="$(sed -E 's/.*uses:[[:space:]]*["'\'']?([^/"'\'' ]+)\/.*/\1/' <<<"$line")"
      [[ "$owner" == "." ]] && continue
      if ! printf '%s\n' "${WF_ALLOWED_ACTION_OWNERS[@]}" | grep -qxF -- "$owner"; then
        echo "$file: $owner is not an allowed action owner"
      fi
    done < <(grep -E '^[[:space:]-]*uses:[[:space:]]*[^ ]+' "$file" || true)
  done < <(workflow_files)
}

only_allowed_workflows_use_pull_request_target() {
  local file
  while IFS= read -r file; do
    if grep -q 'pull_request_target' "$file" \
      && ! printf '%s\n' "${WF_PULL_REQUEST_TARGET_WORKFLOWS[@]}" | grep -qxF -- "$(basename "$file")"; then
      echo "$file uses pull_request_target"
    fi
  done < <(workflow_files)
}

every_script_is_executable() {
  # Mode 120000 is a symlink; its target is checked where it is tracked.
  git ls-files -s -- ':(glob)scripts/*.sh' ':(glob).github/**/*.sh' | awk '$1 != "100755" && $1 != "120000" { print $4 }'
}

decision_records_have_unique_numbers() {
  [[ -d docs/decisions ]] || return 0
  git ls-files -- 'docs/decisions/[0-9][0-9][0-9][0-9]-*.md' \
    | sed -E 's#.*/([0-9]{4})-.*#\1#' | sort | uniq -d | sed 's/^/duplicate ADR number /'
}

run_contract claude_md_imports_agents_md claude_md_imports_agents_md
run_contract claude_skills_point_at_agents_skills claude_skills_point_at_agents_skills
run_contract every_skill_declares_name_and_description every_skill_declares_name_and_description
run_contract every_docs_page_declares_what_it_describes every_docs_page_declares_what_it_describes
run_contract every_describes_pattern_matches_something every_describes_pattern_matches_something
run_contract every_workflow_job_declares_permissions every_workflow_job_declares_permissions
run_contract every_checkout_disables_persisted_credentials every_checkout_disables_persisted_credentials
run_contract every_action_comes_from_an_allowed_owner every_action_comes_from_an_allowed_owner
run_contract only_allowed_workflows_use_pull_request_target only_allowed_workflows_use_pull_request_target
run_contract every_script_is_executable every_script_is_executable
run_contract decision_records_have_unique_numbers decision_records_have_unique_numbers

if [[ $failures -gt 0 ]]; then
  wf_fail "$failures contract(s) failed."
fi

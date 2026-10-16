#!/usr/bin/env bash
# Table test of .github/scripts/gate-integrity.sh (SchoolEngine/.github#22).
# Workflow cases mutate the real templates with yq; ignore cases use the files
# of fixtures/. Run by the `scripts` job of ci.yml.
#
# Usage: tests/gate-integrity/run.sh   (needs yq, jq, python3, git, actionlint)
set -euo pipefail

root=$(git rev-parse --show-toplevel)
script="$root/.github/scripts/gate-integrity.sh"
fixtures="$root/tests/gate-integrity/fixtures"
templates="$root/workflow-templates"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GATE_INTEGRITY_TODAY="2026-10-16"

failures=0
# expect: 0 = passes, 1 = fails. Output is kept for the failing cases only.
expect() {
  local want=$1 label=$2 rc=0
  shift 2
  "$@" >"$work/out.txt" 2>&1 || rc=$?
  if [[ "$rc" -eq "$want" ]]; then
    echo "ok   $label"
  else
    echo "FAIL $label: exit $rc, expected $want"
    sed 's/^/     /' "$work/out.txt"
    failures=$((failures + 1))
  fi
}

# A head ci.yml: the node template, transformed by a yq expression.
head_of() {
  yq "$1" "$templates/ci-node.yml" >"$work/head.yml"
  echo "$work/head.yml"
}

workflow() { "$script" workflow "$templates/ci-node.yml" "$@"; }
not_ci_pr() { PR_TITLE="feat(api): something (#1)" PR_BODY="Closes #1" "$@"; }
ci_pr() {
  PR_TITLE="ci(quality-gate): drop the node job (#1)" \
    PR_BODY=$'Closes #1\n\n## Gate change\n\nThe node job moves to another workflow.\n\n## Review first\n' "$@"
}
ci_pr_empty_section() {
  PR_TITLE="ci(quality-gate): drop the node job (#1)" \
    PR_BODY=$'Closes #1\n\n## Gate change\n\n<!-- why -->\n\n## Review first\n' "$@"
}

echo "== Workflow: legitimate changes"
for t in common node flutter openapi ansible; do
  expect 0 "template ci-$t against itself" not_ci_pr "$script" workflow "$templates/ci-$t.yml" "$templates/ci-$t.yml"
done
expect 0 "a stack job added (ci-common to ci-node)" \
  not_ci_pr "$script" workflow "$templates/ci-common.yml" "$templates/ci-node.yml"
expect 0 "an action SHA bumped (Dependabot)" not_ci_pr workflow \
  "$(head_of '(.jobs.gitleaks.steps[0].uses) = "actions/checkout@0000000000000000000000000000000000000000"')"
expect 0 "a step added to a stack job" not_ci_pr workflow \
  "$(head_of '.jobs.node.steps += [{"name": "Extra", "run": "true"}]')"
expect 0 "no ci.yml on the base branch" not_ci_pr "$script" workflow /dev/null "$templates/ci-node.yml"

echo "== Workflow: hard failures (never accepted)"
expect 1 "a common job removed" ci_pr workflow \
  "$(head_of 'del(.jobs.osv-scanner) | .jobs.quality-gate.needs -= ["osv-scanner"]')"
expect 1 "the gate-integrity job removed" ci_pr workflow \
  "$(head_of 'del(.jobs.gate-integrity) | .jobs.quality-gate.needs -= ["gate-integrity"]')"
expect 1 "needs shrunk (job kept, out of the gate)" ci_pr workflow \
  "$(head_of '.jobs.quality-gate.needs -= ["node"]')"
# shellcheck disable=SC2016  # a literal GitHub expression
expect 1 "gate if: changed to always()" ci_pr workflow \
  "$(head_of '.jobs.quality-gate.if = "${{ always() }}"')"
expect 1 "gate if: removed" ci_pr workflow "$(head_of 'del(.jobs.quality-gate.if)')"
expect 1 "gate renamed" ci_pr workflow "$(head_of '.jobs.quality-gate.name = "Gate"')"
expect 1 "continue-on-error on a job" ci_pr workflow "$(head_of '.jobs.node.continue-on-error = true')"
expect 1 "continue-on-error on a step" ci_pr workflow \
  "$(head_of '.jobs.node.steps[1].continue-on-error = true')"

echo "== Workflow: gate changes (accepted only with a justified ci PR)"
removed=$(head_of 'del(.jobs.node) | .jobs.quality-gate.needs -= ["node"]')
expect 1 "stack job removed, feat PR" not_ci_pr workflow "$removed"
expect 0 "stack job removed, ci PR with a Gate change section" ci_pr workflow "$removed"
expect 1 "stack job removed, ci PR with an empty Gate change section" ci_pr_empty_section workflow "$removed"
expect 1 "stack job removed, no PR text" workflow "$removed"
neutered=$(head_of '.jobs.gitleaks.steps[2].run = "true"')
expect 1 "gitleaks step rewritten, feat PR" not_ci_pr workflow "$neutered"
expect 0 "gitleaks step rewritten, ci PR with a Gate change section" ci_pr workflow "$neutered"
expect 1 "gate script rewritten, feat PR" not_ci_pr workflow \
  "$(head_of '.jobs.quality-gate.steps[0].run = "exit 0"')"

echo "== Ignore files"
ignores_case() {
  local want=$1 label=$2 name=$3 fixture=$4 extra=${5:-}
  rm -rf "$work/base" "$work/head" && mkdir -p "$work/base" "$work/head"
  mkdir -p "$work/head/$(dirname "$name")"
  cp "$fixtures/$fixture" "$work/head/$name"
  # shellcheck disable=SC2086  # $extra is an optional wrapper function name
  expect "$want" "$label" $extra "$script" ignores "$work/base" "$work/head"
}
ignores_case 0 "osv-scanner.toml with reason and expiry" osv-scanner.toml osv-ok.toml
ignores_case 0 "nested osv-scanner.toml with reason and expiry" generators/ts/osv-scanner.toml osv-ok.toml
ignores_case 1 "osv-scanner.toml ignore without expiry" osv-scanner.toml osv-no-expiry.toml
ignores_case 1 "nested osv-scanner.toml ignore without expiry" clients/dart/osv-scanner.toml osv-no-expiry.toml
ignores_case 1 "osv-scanner.toml override without reason" osv-scanner.toml osv-override-no-reason.toml
ignores_case 0 ".gitleaksignore entry with justification and expiry" .gitleaksignore gitleaksignore-ok
ignores_case 1 ".gitleaksignore entry without comment" .gitleaksignore gitleaksignore-no-comment
ignores_case 1 ".gitleaksignore entry expired" .gitleaksignore gitleaksignore-expired
ignores_case 0 ".gitleaks.toml allowlist with justification and expiry" .gitleaks.toml gitleaks-ok.toml
ignores_case 1 ".gitleaks.toml allowlist without expiry" .gitleaks.toml gitleaks-no-expiry.toml
ignores_case 1 ".gitleaks.toml without the default rules, feat PR" .gitleaks.toml gitleaks-no-default.toml not_ci_pr
ignores_case 0 ".gitleaks.toml without the default rules, justified ci PR" .gitleaks.toml gitleaks-no-default.toml ci_pr

echo "== End to end (ci subcommand on a git repository)"
repo="$work/repo"
git init -q -b develop "$repo"
mkdir -p "$repo/.github/workflows" "$repo/.github/scripts"
cp "$templates/ci-node.yml" "$repo/.github/workflows/ci.yml"
cp "$script" "$repo/.github/scripts/gate-integrity.sh"
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm base
yq -i 'del(.jobs.node) | .jobs.quality-gate.needs -= ["node"]' "$repo/.github/workflows/ci.yml"
cp "$fixtures/osv-no-expiry.toml" "$repo/osv-scanner.toml"
ci_run() { (cd "$repo" && "$@" "$script" ci "$(git -C "$repo" rev-parse HEAD)"); }
expect 1 "job removed and an unjustified ignore, feat PR" ci_run not_ci_pr
cp "$fixtures/osv-ok.toml" "$repo/osv-scanner.toml"
expect 1 "job removed, justified ignore, feat PR" ci_run not_ci_pr
expect 0 "job removed, justified ignore, ci PR with a Gate change section" ci_run ci_pr

if [[ "$failures" -gt 0 ]]; then
  echo "$failures case(s) failed."
  exit 1
fi
echo "All cases passed."

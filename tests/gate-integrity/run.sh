#!/usr/bin/env bash
# Table test of .github/scripts/gate-integrity.sh (SchoolEngine/.github#22).
# Workflow cases mutate the real templates with yq; ignore cases use the files
# of fixtures/; approval cases use generated PR metadata. Run by the `scripts`
# job of ci.yml.
#
# Usage: tests/gate-integrity/run.sh   (needs bash 4+, yq, jq, python3, git)
set -euo pipefail

root=$(git rev-parse --show-toplevel)
script="$root/.github/scripts/gate-integrity.sh"
fixtures="$root/tests/gate-integrity/fixtures"
templates="$root/workflow-templates"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GATE_INTEGRITY_TODAY="2026-10-16"
unset PR_JSON_FILE PR_EVENTS_FILE PR_ACTION GATE_CHANGE_APPROVERS GITHUB_STEP_SUMMARY

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

# --- Trees ------------------------------------------------------------------

# A repository tree: a ci.yml (none if empty), the gate-integrity workflow and
# its checker.
tree() {
  local dir=$1 ci=$2
  rm -rf "$dir" && mkdir -p "$dir/.github/workflows" "$dir/.github/scripts"
  [[ -z "$ci" ]] || cp "$ci" "$dir/.github/workflows/ci.yml"
  cp "$templates/gate-integrity.yml" "$dir/.github/workflows/gate-integrity.yml"
  cp "$script" "$dir/.github/scripts/gate-integrity.sh"
}

base="$work/base"
tree "$base" "$templates/ci-node.yml"

# A head tree: the base tree, its ci.yml transformed by a yq expression.
head_of() {
  tree "$work/head" "$templates/ci-node.yml"
  yq -i "$1" "$work/head/.github/workflows/ci.yml"
  echo "$work/head"
}

# A head tree: the base tree plus a file read from stdin.
head_with() {
  tree "$work/head" "$templates/ci-node.yml"
  mkdir -p "$work/head/$(dirname "$1")"
  cat >"$work/head/$1"
  echo "$work/head"
}

check() { "$script" check "$base" "$1"; }

# --- PR metadata ------------------------------------------------------------

approver="celine-approver"
author="Lynerah"
section_body=$'Closes #1\n\n## Gate change\n\nThe node job moves to another workflow.\n\n## Review first\n'

# pr_meta <name> <body> <label on the PR: yes|no> [labeled-by...]
pr_meta() {
  local name=$1 body=$2 present=$3 labels='[]' events='[]' actor
  shift 3
  [[ "$present" == "no" ]] || labels='[{"name": "gate-change-approved"}]'
  for actor in "$@"; do
    events=$(jq --arg a "$actor" '. + [{event: "labeled", label: {name: "gate-change-approved"}, actor: {login: $a}}]' <<<"$events")
  done
  jq -n --arg body "$body" --arg author "$author" --argjson labels "$labels" \
    '{body: $body, user: {login: $author}, labels: $labels}' >"$work/$name.pr.json"
  echo "$events" >"$work/$name.events.json"
}
pr_meta feat "Closes #1" no
pr_meta approved "$section_body" yes "$approver"
pr_meta no-section "Closes #1" yes "$approver"
pr_meta empty-section $'Closes #1\n\n## Gate change\n\n<!-- why -->\n\n## Review first\n' yes "$approver"
pr_meta self "$section_body" yes "$author"
pr_meta stranger "$section_body" yes "someone-else"
pr_meta removed "$section_body" no "$approver"
pr_meta relabeled "$section_body" yes "$approver" "$author"

# as_pr <metadata name> <activity type> <command...>
as_pr() {
  local name=$1 action=$2
  shift 2
  PR_JSON_FILE="$work/$name.pr.json" PR_EVENTS_FILE="$work/$name.events.json" \
    PR_ACTION="$action" GATE_CHANGE_APPROVERS="jonathanpiette, $approver" "$@"
}
feat_pr() { as_pr feat opened "$@"; }
approved_pr() { as_pr approved labeled "$@"; }

echo "== Legitimate changes"
for t in common node flutter openapi ansible; do
  tree "$work/t-base" "$templates/ci-$t.yml"
  tree "$work/t-head" "$templates/ci-$t.yml"
  expect 0 "template ci-$t against itself" feat_pr "$script" check "$work/t-base" "$work/t-head"
done
expect 0 "a stack job added" feat_pr check \
  "$(head_of '.jobs.extra = {"name": "Extra", "runs-on": "ubuntu-latest", "steps": [{"run": "true"}]} | .jobs.quality-gate.needs += ["extra"]')"
expect 0 "an action SHA bumped in ci.yml (Dependabot)" feat_pr check \
  "$(head_of '(.jobs.gitleaks.steps[0].uses) = "actions/checkout@0000000000000000000000000000000000000000"')"
expect 0 "a tool version and its sha256 bumped" feat_pr check \
  "$(head_of '.env.GITLEAKS_VERSION = "8.31.0" | .env.GITLEAKS_SHA256 = "0000"')"
expect 0 "a step added to a stack job" feat_pr check \
  "$(head_of '.jobs.node.steps += [{"name": "Extra", "run": "true"}]')"
head=$(head_of '.')
yq -i '(.jobs.gate-integrity.steps[0].uses) = "actions/checkout@0000000000000000000000000000000000000000"' \
  "$head/.github/workflows/gate-integrity.yml"
expect 0 "an action SHA bumped in gate-integrity.yml (Dependabot)" feat_pr check "$head"
tree "$work/t-base" ""
expect 0 "no ci.yml on the base branch" feat_pr "$script" check "$work/t-base" "$(head_of '.')"

echo "== Hard failures (never accepted, even approved)"
expect 1 "a common job removed" approved_pr check \
  "$(head_of 'del(.jobs.osv-scanner) | .jobs.quality-gate.needs -= ["osv-scanner"]')"
expect 1 "needs shrunk (job kept, out of the gate)" approved_pr check \
  "$(head_of '.jobs.quality-gate.needs -= ["node"]')"
# shellcheck disable=SC2016  # a literal GitHub expression
expect 1 "gate if: changed to always()" approved_pr check \
  "$(head_of '.jobs.quality-gate.if = "${{ always() }}"')"
expect 1 "gate if: removed" approved_pr check "$(head_of 'del(.jobs.quality-gate.if)')"
expect 1 "gate renamed" approved_pr check "$(head_of '.jobs.quality-gate.name = "Gate"')"
expect 1 "continue-on-error on a job" approved_pr check "$(head_of '.jobs.node.continue-on-error = true')"
expect 1 "continue-on-error on a step" approved_pr check \
  "$(head_of '.jobs.node.steps[1].continue-on-error = true')"
expect 1 "custom shell in defaults (true {0})" approved_pr check \
  "$(head_of '.defaults.run.shell = "true {0}"')"
expect 1 "custom shell on a step" approved_pr check \
  "$(head_of '.jobs.node.steps[1].shell = "bash -c true {0}"')"
expect 1 "write permission on a job of ci.yml" approved_pr check \
  "$(head_of '.jobs.node.permissions.statuses = "write"')"
expect 1 "write-all in ci.yml" approved_pr check "$(head_of '.permissions = "write-all"')"
expect 1 "a job named Gate integrity in ci.yml" approved_pr check \
  "$(head_of '.jobs.node.name = "Gate integrity"')"
head=$(head_of '.')
printf 'x: &anchor [1]\n' >>"$head/.github/workflows/ci.yml"
expect 1 "a YAML anchor in ci.yml" approved_pr check "$head"
head=$(head_of '.')
yq -i '.jobs.quality-gate.needs += ["extra"]' "$head/.github/workflows/ci.yml"
printf '  extra:\n    <<: {timeout-minutes: 1}\n    runs-on: ubuntu-latest\n    steps: [{run: "true"}]\n' >>"$head/.github/workflows/ci.yml"
expect 1 "a YAML merge key in ci.yml" approved_pr check "$head"
expect 1 "a new workflow with pull_request_target" approved_pr check "$(head_with .github/workflows/x.yml <<'EOF'
on: pull_request_target
permissions: {}
jobs:
  x: {runs-on: ubuntu-latest, steps: [{run: "true"}]}
EOF
)"
expect 1 "a new workflow with workflow_run" approved_pr check "$(head_with .github/workflows/x.yml <<'EOF'
on:
  workflow_run: {workflows: [CI], types: [completed]}
permissions: {}
jobs:
  x: {runs-on: ubuntu-latest, steps: [{run: "true"}]}
EOF
)"
expect 1 "a new workflow spoofing the Quality Gate check" approved_pr check "$(head_with .github/workflows/x.yaml <<'EOF'
on: pull_request
permissions: {}
jobs:
  x: {name: Quality Gate, runs-on: ubuntu-latest, steps: [{run: "true"}]}
EOF
)"
expect 1 "a new workflow spoofing the Gate integrity check" approved_pr check "$(head_with .github/workflows/x.yml <<'EOF'
on: pull_request
permissions: {}
jobs:
  gate-integrity: {name: gate INTEGRITY, runs-on: ubuntu-latest, steps: [{run: "true"}]}
EOF
)"
expect 1 "a new workflow with statuses: write" approved_pr check "$(head_with .github/workflows/x.yml <<'EOF'
on: pull_request
permissions: {statuses: write}
jobs:
  x: {runs-on: ubuntu-latest, steps: [{run: "true"}]}
EOF
)"
head=$(head_of '.')
rm "$head/.github/workflows/gate-integrity.yml"
expect 1 "gate-integrity.yml removed" approved_pr check "$head"
head=$(head_of '.')
rm "$head/.github/scripts/gate-integrity.sh"
expect 1 "the checker removed" approved_pr check "$head"

echo "== Gate changes: refused unless approved"
gate_change_case() {
  local label=$1 head=$2
  expect 1 "$label, not approved" feat_pr check "$head"
  expect 0 "$label, approved" approved_pr check "$head"
}
gate_change_case "stack job removed" "$(head_of 'del(.jobs.node) | .jobs.quality-gate.needs -= ["node"]')"
gate_change_case "gitleaks step rewritten" "$(head_of '.jobs.gitleaks.steps[2].run = "true"')"
gate_change_case "gate script rewritten" "$(head_of '.jobs.quality-gate.steps[0].run = "exit 0"')"
gate_change_case "trigger changed (on)" "$(head_of '.on.pull_request.types = ["opened"]')"
gate_change_case "workflow permissions changed" "$(head_of '.permissions = {}')"
gate_change_case "defaults added" "$(head_of '.defaults.run.working-directory = "docs"')"
gate_change_case "concurrency changed" "$(head_of '.concurrency.group = "x"')"
tree "$work/t-base" "$templates/ci-common.yml"
expect 1 "template switch ci-common to ci-node (env added), not approved" \
  feat_pr "$script" check "$work/t-base" "$(head_of '.')"
expect 0 "template switch ci-common to ci-node (env added), approved" \
  approved_pr "$script" check "$work/t-base" "$(head_of '.')"
gate_change_case "coverage floor lowered (env)" "$(head_of '.env.COVERAGE_MIN = "10"')"
gate_change_case "workflow env changed (not a version)" "$(head_of '.env.NODE_OPTIONS = "--require ./x.js"')"
gate_change_case "a new workflow" "$(head_with .github/workflows/release.yml <<'EOF'
on: {push: {tags: ['v*']}}
permissions: {contents: read}
jobs:
  x: {runs-on: ubuntu-latest, steps: [{run: "true"}]}
EOF
)"
head=$(head_of '.')
yq -i 'del(.jobs.drop-stale-approval)' "$head/.github/workflows/gate-integrity.yml"
gate_change_case "gate-integrity.yml changed" "$head"
head=$(head_of '.')
echo "# changed" >>"$head/.github/scripts/gate-integrity.sh"
gate_change_case "the checker changed" "$head"

echo "== Approval of a gate change"
removed=$(head_of 'del(.jobs.node) | .jobs.quality-gate.needs -= ["node"]')
expect 0 "approved by a listed approver" approved_pr check "$removed"
expect 0 "approved, then the body edited" as_pr approved edited check "$removed"
expect 1 "approved, no Gate change section" as_pr no-section labeled check "$removed"
expect 1 "approved, empty Gate change section" as_pr empty-section labeled check "$removed"
expect 1 "label applied by the PR author" as_pr self labeled check "$removed"
expect 1 "label applied by someone not listed" as_pr stranger labeled check "$removed"
expect 1 "label removed since" as_pr removed unlabeled check "$removed"
expect 1 "label re-applied by the PR author" as_pr relabeled labeled check "$removed"
expect 1 "new commits pushed after the approval" as_pr approved synchronize check "$removed"
expect 1 "no approver configured" env GATE_CHANGE_APPROVERS= PR_JSON_FILE="$work/approved.pr.json" \
  PR_EVENTS_FILE="$work/approved.events.json" PR_ACTION=labeled "$script" check "$base" "$removed"
expect 1 "no PR metadata" check "$removed"

echo "== Ignore files"
ignores_case() {
  local want=$1 label=$2 name=$3 fixture=$4 wrapper=${5:-feat_pr}
  tree "$work/head" "$templates/ci-node.yml"
  mkdir -p "$work/head/$(dirname "$name")"
  cp "$fixtures/$fixture" "$work/head/$name"
  expect "$want" "$label" "$wrapper" check "$work/head"
}
ignores_case 0 "osv-scanner.toml with reason and expiry" osv-scanner.toml osv-ok.toml
ignores_case 0 "osv-scanner.toml with a datetime expiry" osv-scanner.toml osv-datetime.toml
ignores_case 0 "nested osv-scanner.toml with reason and expiry" generators/ts/osv-scanner.toml osv-ok.toml
ignores_case 1 "osv-scanner.toml ignore without expiry" osv-scanner.toml osv-no-expiry.toml
ignores_case 1 "nested osv-scanner.toml ignore without expiry" clients/dart/osv-scanner.toml osv-no-expiry.toml
ignores_case 1 "osv-scanner.toml override without reason" osv-scanner.toml osv-override-no-reason.toml
ignores_case 1 "osv-scanner.toml ignore expired" osv-scanner.toml osv-expired.toml
ignores_case 1 "osv-scanner.toml expiry beyond 180 days" osv-scanner.toml osv-too-far.toml
ignores_case 1 "osv-scanner.toml reason too short" osv-scanner.toml osv-short-reason.toml
ignores_case 0 ".gitleaksignore entry with justification and expiry" .gitleaksignore gitleaksignore-ok
ignores_case 1 ".gitleaksignore entry without comment" .gitleaksignore gitleaksignore-no-comment
ignores_case 1 ".gitleaksignore entry expired" .gitleaksignore gitleaksignore-expired
ignores_case 1 ".gitleaksignore expiry beyond 180 days" .gitleaksignore gitleaksignore-too-far
ignores_case 1 ".gitleaksignore justification too short" .gitleaksignore gitleaksignore-short
ignores_case 0 ".gitleaks.toml allowlist with justification and expiry" .gitleaks.toml gitleaks-ok.toml
ignores_case 1 ".gitleaks.toml allowlist without expiry" .gitleaks.toml gitleaks-no-expiry.toml
ignores_case 1 ".gitleaks.toml without the default rules, not approved" .gitleaks.toml gitleaks-no-default.toml
ignores_case 0 ".gitleaks.toml without the default rules, approved" .gitleaks.toml gitleaks-no-default.toml approved_pr

echo "== Workflow command injection"
ignores_case 1 "an osv id holding a newline and '::error::'" osv-scanner.toml osv-injection.toml
if grep -q '^::error::injected' "$work/out.txt"; then
  echo "FAIL PR text opened a workflow command"
  failures=$((failures + 1))
else
  echo "ok   PR text escaped in annotations"
fi
head=$(head_with .github/workflows/x.yml <<'EOF'
on: pull_request
permissions: {}
jobs:
  x: {runs-on: ubuntu-latest, steps: [{run: "true"}]}
::error::injected from a workflow file: 1
EOF
)
expect 1 "a new workflow printed in the log" feat_pr check "$head"
if awk '/^::stop-commands::/ { stopped = 1 } /^::[0-9a-f]+::$/ { stopped = 0 }
        /::error::injected/ && !stopped { bad = 1 } END { exit bad ? 0 : 1 }' "$work/out.txt"; then
  echo "FAIL PR text printed outside the stop-commands markers"
  failures=$((failures + 1))
else
  echo "ok   PR text printed between stop-commands markers"
fi

echo "== End to end (ci subcommand on git commits)"
repo="$work/repo"
tree "$repo" "$templates/ci-node.yml"
git init -q -b develop "$repo"
commit() {
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm "$1"
}
commit base
base_sha=$(git -C "$repo" rev-parse HEAD)
ci_run() { (cd "$repo" && "$@" "$script" ci "$base_sha" "$(git rev-parse HEAD)"); }
yq -i 'del(.jobs.node) | .jobs.quality-gate.needs -= ["node"]' "$repo/.github/workflows/ci.yml"
cp "$fixtures/osv-no-expiry.toml" "$repo/osv-scanner.toml"
commit "job removed, unjustified ignore"
expect 1 "job removed and an unjustified ignore, approved" ci_run approved_pr
cp "$fixtures/osv-ok.toml" "$repo/osv-scanner.toml"
commit "justified ignore"
expect 1 "job removed, justified ignore, not approved" ci_run feat_pr
expect 0 "job removed, justified ignore, approved" ci_run approved_pr
echo "not read by the checker" >"$repo/$(printf 'odd\nname.txt')"
commit "a file name with a newline"
expect 0 "a file name with a newline in the tree" ci_run approved_pr

if [[ "$failures" -gt 0 ]]; then
  echo "$failures case(s) failed."
  exit 1
fi
echo "All cases passed."

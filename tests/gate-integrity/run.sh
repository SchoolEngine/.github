#!/usr/bin/env bash
# Table test of .github/scripts/gate-integrity.sh and of the invariants of
# workflow-templates/gate-integrity.yml (SchoolEngine/.github#22). Workflow
# cases mutate the real templates with yq; ignore cases use the files of
# fixtures/; PR metadata is generated. Run by the `scripts` job of ci.yml.
#
# Usage: tests/gate-integrity/run.sh   (needs bash 4+, yq, jq, python3, git)
# shellcheck disable=SC2016  # literal GitHub expressions in yq programs throughout
set -euo pipefail

root=$(git rev-parse --show-toplevel)
script="$root/.github/scripts/gate-integrity.sh"
fixtures="$root/tests/gate-integrity/fixtures"
templates="$root/workflow-templates"
workflow="$templates/gate-integrity.yml"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GATE_INTEGRITY_TODAY="2026-10-16"
unset PR_JSON_FILE GITHUB_STEP_SUMMARY

failures=0
fail() {
  echo "FAIL $1"
  failures=$((failures + 1))
}

# expect: 0 = passes, 1 = fails. Output is kept for the failing cases only.
expect() {
  local want=$1 label=$2 rc=0
  shift 2
  "$@" >"$work/out.txt" 2>&1 || rc=$?
  if [[ "$rc" -eq "$want" ]]; then
    echo "ok   $label"
  else
    fail "$label: exit $rc, expected $want"
    sed 's/^/     /' "$work/out.txt"
  fi
}

# assert <label> <jq expression on the workflow as JSON that must be true>
workflow_json=$(yq -o json '.' "$workflow")
assert() {
  if [[ "$(jq "$2" <<<"$workflow_json")" == "true" ]]; then
    echo "ok   $1"
  else
    fail "$1"
  fi
}

echo "== Invariants of the gate-integrity workflow"
assert "only the pull_request_target trigger" '(.on | keys) == ["pull_request_target"]'
assert "triggers on opened, synchronize, reopened and edited" \
  '(.on.pull_request_target.types | sort) == ["edited", "opened", "reopened", "synchronize"]'
assert "permissions: {} at the top" '.permissions == {}'
assert "only read permissions in jobs" \
  '[.jobs[].permissions // {} | .[] | select(. != "read")] | length == 0'
assert "no ref: on any checkout (the default branch only)" \
  '[.jobs[].steps[] | select(.uses // "" | test("^actions/checkout@")) | .with.ref // empty] | length == 0'
assert "checkout without persisted credentials" \
  '[.jobs[].steps[] | select(.uses // "" | test("^actions/checkout@")) | select(.with["persist-credentials"] != false)] | length == 0'
assert "no expression in any run: script" \
  '[.jobs[].steps[] | .run // "" | select(test("[$][{][{]"))] | length == 0'
assert "no PR title, body or branch anywhere in the workflow" \
  '[.. | strings | select(test("pull_request[.](title|body|head[.]ref)|github[.]head_ref|pull_request[.]labels"))] | length == 0'
assert "actions pinned by full commit SHA" \
  '[.jobs[].steps[] | .uses // empty | select(test("@[0-9a-f]{40}$") | not)] | length == 0'
if cmp -s "$workflow" "$root/.github/workflows/gate-integrity.yml"; then
  echo "ok   the live copy is the template"
else
  fail "the live copy .github/workflows/gate-integrity.yml differs from the template"
fi

# --- Trees ------------------------------------------------------------------

# A repository tree: a ci.yml (none if empty), the gate-integrity workflow and
# its checker.
tree() {
  local dir=$1 ci=$2
  rm -rf "$dir" && mkdir -p "$dir/.github/workflows" "$dir/.github/scripts"
  [[ -z "$ci" ]] || cp "$ci" "$dir/.github/workflows/ci.yml"
  cp "$workflow" "$dir/.github/workflows/gate-integrity.yml"
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

# A head tree: the base tree with a raw line appended to ci.yml.
head_append() {
  tree "$work/head" "$templates/ci-node.yml"
  printf '%s\n' "$1" >>"$work/head/.github/workflows/ci.yml"
  echo "$work/head"
}

check() { "$script" check "$base" "$1"; }

# --- PR metadata ------------------------------------------------------------

# pr_meta <name> <author> <body>
pr_meta() {
  jq -n --arg author "$2" --arg body "$3" '{body: $body, user: {login: $author}}' >"$work/$1.pr.json"
}
justification="The node job moves to a separate workflow, reviewed in this PR."
pr_meta feat contributor "Closes #1"
pr_meta justified contributor $'Closes #1\n\n## Gate change\n\n'"$justification"$'\n\n## Review first\n'
pr_meta dependabot "dependabot[bot]" "Bumps actions/checkout."
# commits <name> <author:verified>...
commits() {
  local name=$1 list='[]' spec
  shift
  for spec in "$@"; do
    list=$(jq --arg a "${spec%%:*}" --argjson v "${spec##*:}" '. + [{author: {login: $a}, commit: {verification: {verified: $v}}}]' <<<"$list")
  done
  echo "$list" >"$work/$name.commits.json"
}
commits signed "dependabot[bot]:true" "dependabot[bot]:true"
commits unsigned "dependabot[bot]:true" "dependabot[bot]:false"
commits mixed "dependabot[bot]:true" "contributor:true"
pr_meta no-section contributor $'Closes #1\n\n## Review first\n\n'"$justification"
pr_meta empty-section contributor $'Closes #1\n\n## Gate change\n\n## Review first\n'
pr_meta comment-only contributor $'Closes #1\n\n## Gate change\n\n<!-- '"$justification"$' -->\n\n## Review first\n'
pr_meta multiline-comment contributor $'Closes #1\n\n## Gate change\n\n<!--\n'"$justification"$'\n-->\nok\n'
pr_meta unterminated-comment contributor $'Closes #1\n\n## Gate change\n\nok <!-- '"$justification"
pr_meta heading-in-comment contributor $'Closes #1\n\n<!--\n## Gate change\n\n'"$justification"$'\n-->\n'
pr_meta short contributor $'Closes #1\n\n## Gate change\n\nNeeded, see issue.\n'
pr_meta crlf contributor $'Closes #1\r\n\r\n## Gate change\r\n\r\n'"$justification"$'\r\n'

as_pr() {
  local name=$1
  shift
  PR_JSON_FILE="$work/$name.pr.json" "$@"
}
feat_pr() { as_pr feat "$@"; }
justified_pr() { as_pr justified "$@"; }
dependabot_pr() { PR_COMMITS_FILE="$work/signed.commits.json" as_pr dependabot "$@"; }

sha_a="0000000000000000000000000000000000000000"
sha64="1111111111111111111111111111111111111111111111111111111111111111"

echo "== Legitimate changes"
for t in common node flutter openapi ansible; do
  tree "$work/t-base" "$templates/ci-$t.yml"
  tree "$work/t-head" "$templates/ci-$t.yml"
  expect 0 "template ci-$t against itself" feat_pr "$script" check "$work/t-base" "$work/t-head"
done
expect 0 "a stack job added" feat_pr check \
  "$(head_of '.jobs.extra = {"name": "Extra", "runs-on": "ubuntu-latest", "steps": [{"run": "true"}]} | .jobs.quality-gate.needs += ["extra"]')"
expect 0 "a step added to a stack job" feat_pr check \
  "$(head_of '.jobs.node.steps += [{"name": "Extra", "run": "true"}]')"
expect 0 "a matrix stack job (names get a suffix, never a check name)" feat_pr check \
  "$(head_of '.jobs.node.strategy.matrix.os = ["a", "b"]')"
expect 0 "an explicit continue-on-error: false" feat_pr check "$(head_of '.jobs.node.continue-on-error = false')"
expect 0 "Code quality (matrix value): only exact reserved names matter" feat_pr check \
  "$(head_of '.jobs.node.name = "Code quality (${{ matrix.os }})" | .jobs.node.strategy.matrix.os = ["Quality Gate"]')"
expect 0 "a matrix job name built from a matrix value" feat_pr check \
  "$(head_of '.jobs.node.name = "Test (${{ matrix.os }})" | .jobs.node.strategy.matrix.os = ["ubuntu", "macos"]')"
expect 0 "a local action under .github/actions/" feat_pr check \
  "$(head_of '.jobs.node.steps += [{"uses": "./.github/actions/setup"}]')"
expect 0 "a version without sha256 bumped" feat_pr check "$(head_of '.env.YAMLLINT_VERSION = "1.39.0"')"
expect 0 "Dependabot: an action SHA bumped in ci.yml" dependabot_pr check \
  "$(head_of "(.jobs.gitleaks.steps[0].uses) = \"actions/checkout@$sha_a\"")"
tree "$work/t-base" ""
expect 0 "no ci.yml on the base branch" feat_pr "$script" check "$work/t-base" "$(head_of '.')"

echo "== Hard failures (never accepted, even justified)"
expect 1 "a common job removed" justified_pr check \
  "$(head_of 'del(.jobs.osv-scanner) | .jobs.quality-gate.needs -= ["osv-scanner"]')"
expect 1 "needs shrunk (job kept, out of the gate)" justified_pr check \
  "$(head_of '.jobs.quality-gate.needs -= ["node"]')"
# shellcheck disable=SC2016  # literal GitHub expressions
expect 1 "gate if: changed to always()" justified_pr check \
  "$(head_of '.jobs.quality-gate.if = "${{ always() }}"')"
expect 1 "gate if: removed" justified_pr check "$(head_of 'del(.jobs.quality-gate.if)')"
expect 1 "gate renamed" justified_pr check "$(head_of '.jobs.quality-gate.name = "Gate"')"
expect 1 "continue-on-error on a job" justified_pr check "$(head_of '.jobs.node.continue-on-error = true')"
expect 1 "continue-on-error on a step" justified_pr check \
  "$(head_of '.jobs.node.steps[1].continue-on-error = true')"
expect 1 "custom shell in defaults (true {0})" justified_pr check \
  "$(head_of '.defaults.run.shell = "true {0}"')"
for shell in "bash -c true {0}" "python cmd" "bash sh" "sh pwsh"; do
  expect 1 "custom shell on a step ($shell)" justified_pr check \
    "$(head_of ".jobs.node.steps[1].shell = \"$shell\"")"
done
expect 1 "write permission on a job of ci.yml" justified_pr check \
  "$(head_of '.jobs.node.permissions.statuses = "write"')"
expect 1 "write-all in ci.yml" justified_pr check "$(head_of '.permissions = "write-all"')"
expect 1 "no top-level permissions in ci.yml" justified_pr check "$(head_of 'del(.permissions)')"
expect 1 "write-all on a push workflow" justified_pr check "$(head_with .github/workflows/x.yml <<'EOF'
on: push
permissions: write-all
jobs:
  x: {runs-on: ubuntu-latest, steps: [{run: "true"}]}
EOF
)"
expect 1 "a job named Gate integrity in ci.yml" justified_pr check \
  "$(head_of '.jobs.node.name = "Gate integrity"')"
# shellcheck disable=SC2016  # literal GitHub expressions
expect 1 "a job name built from a format() expression" justified_pr check \
  "$(head_of '.jobs.node.name = "${{ format(''{0} {1}'', ''Quality'', ''Gate'') }}"')"
expect 1 "a job name that is only a matrix value (could be Quality Gate)" justified_pr check \
  "$(head_of '.jobs.node.name = "${{ matrix.x }}" | .jobs.node.strategy.matrix.x = ["Quality Gate"]')"
expect 1 "a reserved name concatenated from three matrix values" justified_pr check \
  "$(head_of '.jobs.node.name = "${{ matrix.a }}${{ matrix.b }}${{ matrix.c }}" | .jobs.node.strategy.matrix = {"a": ["Qual"], "b": ["ity Ga"], "c": ["te"]}')"
expect 1 "a reserved name built around a matrix value" justified_pr check \
  "$(head_of '.jobs.node.name = "Qual${{ matrix.a }}te" | .jobs.node.strategy.matrix.a = ["ity Ga"]')"
expect 1 "literal Gate next to a matrix value" justified_pr check \
  "$(head_of '.jobs.node.name = "Gate ${{ matrix.x }}" | .jobs.node.strategy.matrix.x = ["a"]')"
expect 1 "a local action outside .github/actions/" justified_pr check \
  "$(head_of '.jobs.node.steps += [{"uses": "./scripts/action"}]')"
expect 1 "a local action escaping .github/actions/" justified_pr check \
  "$(head_of '.jobs.node.steps += [{"uses": "./.github/actions/../../x"}]')"
expect 1 "a non-canonical top-level key (On)" justified_pr check "$(head_of '.On = .on | del(.on)')"
expect 1 "a sha256 removed while its version stays" justified_pr check "$(head_of 'del(.env.GITLEAKS_SHA256)')"
expect 1 "a YAML anchor in ci.yml" justified_pr check "$(head_append 'x: &anchor [1]')"
head=$(head_of '.jobs.quality-gate.needs += ["extra"]')
printf '  extra:\n    <<: {timeout-minutes: 1}\n    runs-on: ubuntu-latest\n    steps: [{run: "true"}]\n' >>"$head/.github/workflows/ci.yml"
expect 1 "a YAML merge key in ci.yml" justified_pr check "$head"
head=$(head_of '.')
sed -i.bak 's/^permissions:/permissions: {}\npermissions:/' "$head/.github/workflows/ci.yml"
expect 1 "duplicate keys in ci.yml" justified_pr check "$head"
expect 1 "a second YAML document in ci.yml" justified_pr check "$(head_append $'---\non: push')"
expect 1 "a tool version that is not a version" justified_pr check "$(head_of '.env.YAMLLINT_VERSION = "latest"')"
expect 1 "a tool version downgraded" justified_pr check "$(head_of '.env.YAMLLINT_VERSION = "1.9.0"')"
expect 1 "a version bumped without its sha256" justified_pr check "$(head_of '.env.GITLEAKS_VERSION = "8.31.0"')"
expect 1 "a sha256 changed without its version" justified_pr check "$(head_of ".env.GITLEAKS_SHA256 = \"$sha64\"")"
expect 1 "a sha256 that is not one" justified_pr check \
  "$(head_of '.env.GITLEAKS_VERSION = "8.31.0" | .env.GITLEAKS_SHA256 = "abc"')"
new_workflow_case() {
  expect 1 "a new workflow $1" justified_pr check "$(head_with .github/workflows/x.yml)"
}
new_workflow_case "with pull_request_target" <<'EOF'
on: pull_request_target
permissions: {}
jobs:
  x: {runs-on: ubuntu-latest, steps: [{run: "true"}]}
EOF
new_workflow_case "with workflow_run" <<'EOF'
on:
  workflow_run: {workflows: [CI], types: [completed]}
permissions: {}
jobs:
  x: {runs-on: ubuntu-latest, steps: [{run: "true"}]}
EOF
new_workflow_case "spoofing the Quality Gate check" <<'EOF'
on: pull_request
permissions: {}
jobs:
  x: {name: Quality Gate, runs-on: ubuntu-latest, steps: [{run: "true"}]}
EOF
new_workflow_case "spoofing the Gate integrity check" <<'EOF'
on: pull_request
permissions: {}
jobs:
  gate-integrity: {name: gate INTEGRITY, runs-on: ubuntu-latest, steps: [{run: "true"}]}
EOF
new_workflow_case "with statuses: write" <<'EOF'
on: pull_request
permissions: {statuses: write}
jobs:
  x: {runs-on: ubuntu-latest, steps: [{run: "true"}]}
EOF
new_workflow_case "with write on issue_comment" <<'EOF'
on: issue_comment
permissions: {pull-requests: write}
jobs:
  x: {runs-on: ubuntu-latest, steps: [{run: "true"}]}
EOF
new_workflow_case "without top-level permissions" <<'EOF'
on: pull_request
jobs:
  x: {runs-on: ubuntu-latest, permissions: {contents: read}, steps: [{run: "true"}]}
EOF
head=$(head_of '.')
rm "$head/.github/workflows/gate-integrity.yml"
expect 1 "gate-integrity.yml removed" justified_pr check "$head"
head=$(head_of '.')
rm "$head/.github/scripts/gate-integrity.sh"
expect 1 "the checker removed" justified_pr check "$head"

echo "== Gate changes: refused unless justified"
gate_change_case() {
  local label=$1 head=$2
  expect 1 "$label, no justification" feat_pr check "$head"
  expect 0 "$label, justified" justified_pr check "$head"
}
gate_change_case "stack job removed" "$(head_of 'del(.jobs.node) | .jobs.quality-gate.needs -= ["node"]')"
gate_change_case "gitleaks step rewritten" "$(head_of '.jobs.gitleaks.steps[2].run = "true"')"
gate_change_case "gate script rewritten" "$(head_of '.jobs.quality-gate.steps[0].run = "exit 0"')"
gate_change_case "an action SHA changed by a person" \
  "$(head_of "(.jobs.gitleaks.steps[0].uses) = \"actions/checkout@$sha_a\"")"
gate_change_case "a tool version bumped with its sha256" \
  "$(head_of ".env.GITLEAKS_VERSION = \"8.31.0\" | .env.GITLEAKS_SHA256 = \"$sha64\"")"
gate_change_case "a release workflow with contents: write on push" "$(head_with .github/workflows/release.yml <<'EOF'
on: {push: {tags: ['v*']}}
permissions: {contents: write}
jobs:
  x: {runs-on: ubuntu-latest, steps: [{run: "true"}]}
EOF
)"
for f in .yamllint.yml .markdownlint-cli2.yaml .github/actionlint.yaml .github/dependabot.yml; do
  gate_change_case "$f added" "$(head_with "$f" <<<'x: 1')"
done
gate_change_case "trigger changed (on)" "$(head_of '.on.pull_request.types = ["opened"]')"
gate_change_case "workflow permissions changed" "$(head_of '.permissions = {}')"
gate_change_case "defaults added" "$(head_of '.defaults.run.working-directory = "docs"')"
gate_change_case "concurrency changed" "$(head_of '.concurrency.group = "x"')"
gate_change_case "coverage floor lowered (env)" "$(head_of '.env.COVERAGE_MIN = "10"')"
gate_change_case "workflow env added (BASH_ENV)" "$(head_of '.env.BASH_ENV = "./x.sh"')"
tree "$work/t-base" "$templates/ci-common.yml"
expect 1 "template switch ci-common to ci-node (env added), no justification" \
  feat_pr "$script" check "$work/t-base" "$(head_of '.')"
expect 0 "template switch ci-common to ci-node (env added), justified" \
  justified_pr "$script" check "$work/t-base" "$(head_of '.')"
gate_change_case "a new workflow" "$(head_with .github/workflows/release.yml <<'EOF'
on: {push: {tags: ['v*']}}
permissions: {contents: read}
jobs:
  x: {runs-on: ubuntu-latest, steps: [{run: "true"}]}
EOF
)"
head=$(head_of '.')
yq -i '.jobs.gate-integrity.timeout-minutes = 30' "$head/.github/workflows/gate-integrity.yml"
gate_change_case "gate-integrity.yml changed" "$head"
head=$(head_of '.')
yq -i "(.jobs.gate-integrity.steps[0].uses) = \"actions/checkout@$sha_a\"" "$head/.github/workflows/gate-integrity.yml"
expect 1 "Dependabot: an action SHA bumped in gate-integrity.yml (never normalized)" dependabot_pr check "$head"
sha_bump=$(head_of "(.jobs.gitleaks.steps[0].uses) = \"actions/checkout@$sha_a\"")
expect 1 "Dependabot PR with an unsigned commit: SHA bump not ignored" \
  env PR_COMMITS_FILE="$work/unsigned.commits.json" PR_JSON_FILE="$work/dependabot.pr.json" "$script" check "$base" "$sha_bump"
expect 1 "Dependabot PR with a commit by someone else: SHA bump not ignored" \
  env PR_COMMITS_FILE="$work/mixed.commits.json" PR_JSON_FILE="$work/dependabot.pr.json" "$script" check "$base" "$sha_bump"
expect 1 "Dependabot PR without the commit list: SHA bump not ignored" as_pr dependabot check "$sha_bump"
expect 1 "Dependabot: the action repository changed" dependabot_pr check \
  "$(head_of "(.jobs.gitleaks.steps[0].uses) = \"evil/checkout@$sha_a\"")"
head=$(head_of '.')
echo "# changed" >>"$head/.github/scripts/gate-integrity.sh"
gate_change_case "the checker changed" "$head"
gate_change_case "a local action added" "$(head_with .github/actions/setup/action.yml <<'EOF'
runs: {using: composite, steps: [{run: "true", shell: bash}]}
EOF
)"
mkdir -p "$base/.github/actions/setup"
echo 'runs: {using: composite, steps: [{run: "true", shell: bash}]}' >"$base/.github/actions/setup/action.yml"
gate_change_case "a local action removed" "$(head_of '.')"
gate_change_case "a local action changed" "$(head_with .github/actions/setup/action.yml <<'EOF'
runs: {using: composite, steps: [{run: "exit 0", shell: bash}]}
EOF
)"
rm -rf "$base/.github/actions"

echo "== The Gate change justification"
removed=$(head_of 'del(.jobs.node) | .jobs.quality-gate.needs -= ["node"]')
expect 0 "a justification of 20 letters or more" justified_pr check "$removed"
expect 0 "CRLF line endings" as_pr crlf check "$removed"
expect 1 "no Gate change section" as_pr no-section check "$removed"
expect 1 "an empty section" as_pr empty-section check "$removed"
expect 1 "the justification inside an HTML comment" as_pr comment-only check "$removed"
expect 1 "a multi-line HTML comment, 2 letters outside" as_pr multiline-comment check "$removed"
expect 1 "an unterminated HTML comment" as_pr unterminated-comment check "$removed"
expect 1 "the section heading inside an HTML comment" as_pr heading-in-comment check "$removed"
expect 1 "a justification under 20 letters" as_pr short check "$removed"
expect 1 "no PR metadata" check "$removed"

echo "== Ignore files"
ignores_case() {
  local want=$1 label=$2 name=$3 fixture=$4 wrapper=${5:-feat_pr}
  tree "$work/head" "$templates/ci-node.yml"
  mkdir -p "$work/head/$(dirname "$name")"
  cp "$fixtures/$fixture" "$work/head/$name"
  expect "$want" "$label" "$wrapper" check "$work/head"
}
# The same rule changed against a base that already has it: a gate change.
mkdir -p "$work/rules-base"
cp -R "$base/." "$work/rules-base/"
cp "$fixtures/gitleaks-rule.toml" "$work/rules-base/.gitleaks.toml"
tree "$work/head" "$templates/ci-node.yml"
sed 's/xyz/abc/' "$fixtures/gitleaks-rule.toml" >"$work/head/.gitleaks.toml"
expect 1 ".gitleaks.toml a rule changed, no justification" feat_pr "$script" check "$work/rules-base" "$work/head"
cp "$fixtures/gitleaks-rule.toml" "$work/head/.gitleaks.toml"
expect 0 ".gitleaks.toml rules unchanged" feat_pr "$script" check "$work/rules-base" "$work/head"
ignores_case 0 "osv-scanner.toml with reason and expiry" osv-scanner.toml osv-ok.toml
ignores_case 0 "osv-scanner.toml with a datetime expiry" osv-scanner.toml osv-datetime.toml
ignores_case 0 "nested osv-scanner.toml with reason and expiry" generators/ts/osv-scanner.toml osv-ok.toml
ignores_case 0 "osv-scanner.toml under node_modules is not ours" node_modules/x/osv-scanner.toml osv-no-expiry.toml
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
ignores_case 1 ".gitleaks.toml without the default rules, no justification" .gitleaks.toml gitleaks-no-default.toml
ignores_case 0 ".gitleaks.toml without the default rules, justified" .gitleaks.toml gitleaks-no-default.toml justified_pr
ignores_case 1 ".gitleaks.toml [AllowList] (mixed case) without expiry" .gitleaks.toml gitleaks-allowlist-case.toml justified_pr
ignores_case 1 ".gitleaks.toml DisabledRules (mixed case), no justification" .gitleaks.toml gitleaks-disabledrules-case.toml
ignores_case 0 ".gitleaks.toml DisabledRules (mixed case), justified" .gitleaks.toml gitleaks-disabledrules-case.toml justified_pr
ignores_case 1 ".gitleaks.toml keys differing only by case" .gitleaks.toml gitleaks-duplicate-case.toml justified_pr
ignores_case 1 ".gitleaks.toml [extend] path" .gitleaks.toml gitleaks-extend-path.toml justified_pr
ignores_case 1 ".gitleaks.toml a rule added, no justification" .gitleaks.toml gitleaks-rule.toml
ignores_case 0 ".gitleaks.toml a rule added, justified" .gitleaks.toml gitleaks-rule.toml justified_pr
ignores_case 1 ".gitleaks.toml not valid TOML" .gitleaks.toml gitleaksignore-ok justified_pr
ignores_case 1 "osv-scanner.toml [[ignoredvulns]] (lowercase) without expiry" osv-scanner.toml osv-lowercase.toml
ignores_case 1 "osv-scanner.toml in a build/ folder is checked" build/osv-scanner.toml osv-no-expiry.toml

echo "== Workflow command injection"
ignores_case 1 "an osv id holding a newline and '::error::'" osv-scanner.toml osv-injection.toml
if grep -q '^::error::injected' "$work/out.txt"; then
  fail "PR text opened a workflow command"
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
  fail "PR text printed outside the stop-commands markers"
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
expect 1 "job removed and an unjustified ignore, justified PR" ci_run justified_pr
cp "$fixtures/osv-ok.toml" "$repo/osv-scanner.toml"
commit "justified ignore"
expect 1 "job removed, justified ignore, no justification" ci_run feat_pr
expect 0 "job removed, justified ignore, justified PR" ci_run justified_pr
echo "not read by the checker" >"$repo/$(printf 'odd\nname.txt')"
mkdir -p "$repo/node_modules/x" && cp "$fixtures/osv-no-expiry.toml" "$repo/node_modules/x/osv-scanner.toml"
commit "a file name with a newline, a vendored osv-scanner.toml"
expect 0 "a file name with a newline, a vendored osv-scanner.toml" ci_run justified_pr
mkdir -p "$repo/.github/actions/setup" && echo 'runs: {using: composite, steps: []}' >"$repo/.github/actions/setup/action.yml"
commit "a local action"
expect 1 "a local action added, no justification" ci_run feat_pr

if [[ "$failures" -gt 0 ]]; then
  echo "$failures case(s) failed."
  exit 1
fi
echo "All cases passed."

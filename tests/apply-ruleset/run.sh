#!/usr/bin/env bash
# Table test of scripts/apply-ruleset.sh (SchoolEngine/.github#23), without
# network: `gh` is a stub that serves one organisation ruleset (id 1,
# `protect-develop`) and one repository ruleset of SchoolEngine/contracts
# (id 2, `protect-release-tags`), and records every write it receives.
#
# Usage: tests/apply-ruleset/run.sh   (needs jq)
set -euo pipefail

root=$(git rev-parse --show-toplevel)
script="$root/scripts/apply-ruleset.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

jq '. + {id: 1, source_type: "Organization"}' "$root/rulesets/protect-develop.json" >"$work/live-org.json"
cat >"$work/live-repo.json" <<'JSON'
{"id": 2, "name": "protect-release-tags", "target": "tag", "enforcement": "active",
 "source_type": "Repository", "bypass_actors": [],
 "conditions": {"ref_name": {"exclude": [], "include": ["refs/tags/v*"]}},
 "rules": [{"type": "deletion"}, {"type": "non_fast_forward"}, {"type": "update"}]}
JSON

cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >>"$GH_STUB_LOG"
[[ "$1" == "api" ]] || exit 3
shift
case "$*" in
  "orgs/SchoolEngine/rulesets --paginate") jq -c '[{id, name}]' "$GH_STUB_DIR/live-org.json" ;;
  "orgs/SchoolEngine/rulesets/1") cat "$GH_STUB_DIR/live-org.json" ;;
  "repos/SchoolEngine/contracts/rulesets?includes_parents=false --paginate") jq -c '[{id, name}]' "$GH_STUB_DIR/live-repo.json" ;;
  "repos/SchoolEngine/contracts/rulesets/2") cat "$GH_STUB_DIR/live-repo.json" ;;
  -X\ PUT\ *|-X\ POST\ *) echo "write recorded" ;;
  *) echo "stub: unexpected call: gh api $*" >&2; exit 4 ;;
esac
STUB
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" GH_STUB_DIR="$work" GH_STUB_LOG="$work/gh.log"

failures=0
# expect <exit> <label> <expected write or "-" for none> -- <args...>
expect() {
  local want=$1 label=$2 write=$3 rc=0
  shift 4
  : >"$GH_STUB_LOG"
  "$script" "$@" >"$work/out.txt" 2>&1 || rc=$?
  local got
  got=$(grep -E '^gh api -X (PUT|POST) ' "$GH_STUB_LOG" | awk '{print $4, $5}' || true)
  [[ -n "$got" ]] || got="-"
  if [[ "$rc" -eq "$want" && "$got" == "$write" ]]; then
    echo "ok   $label"
  else
    echo "FAIL $label: exit $rc (expected $want), write '$got' (expected '$write')"
    sed 's/^/     /' "$work/out.txt"
    failures=$((failures + 1))
  fi
}

ruleset() { jq "$1" "$root/rulesets/protect-develop.json" >"$work/$2"; echo "$work/$2"; }
repo_ruleset() { jq "$1" "$work/live-repo.json" | jq 'del(.id, .source_type)' >"$work/$2"; echo "$work/$2"; }

echo "== The committed rulesets"
if [[ "$(jq -c '.bypass_actors' "$root/rulesets/protect-develop.json")" == "[]" ]]; then
  echo "ok   protect-develop.json has no bypass actor"
else
  echo "FAIL protect-develop.json declares bypass actors"
  failures=$((failures + 1))
fi

echo "== Organisation rulesets"
expect 0 "file matches live: nothing to do" - -- "$root/rulesets/protect-develop.json"
expect 0 "file matches live, --apply: no write" - -- --apply "$root/rulesets/protect-develop.json"
changed=$(ruleset '.enforcement = "evaluate"' changed.json)
expect 0 "file differs: dry-run writes nothing" - -- "$changed"
expect 0 "file differs, --apply: PUT on the organisation ruleset" "PUT orgs/SchoolEngine/rulesets/1" -- --apply "$changed"
created=$(ruleset '.name = "new-ruleset"' created.json)
expect 0 "unknown name: dry-run writes nothing" - -- "$created"
expect 0 "unknown name, --apply: POST" "POST orgs/SchoolEngine/rulesets" -- --apply "$created"

echo "== Refusals"
expect 1 "no bypass_actors key" - -- --apply "$(ruleset 'del(.bypass_actors) | .enforcement = "evaluate"' nobypasskey.json)"
for value in null '{}' '"none"'; do
  expect 1 "bypass_actors not an array ($value)" - -- --apply --allow-bypass "$(ruleset ".bypass_actors = $value" notarray.json)"
done
expect 1 "not a ruleset" - -- "$(ruleset '{name}' notruleset.json)"
bypass=$(ruleset '.bypass_actors = [{"actor_id": 15368, "actor_type": "Integration", "bypass_mode": "always"}]' bypass.json)
expect 1 "bypass actor without --allow-bypass" - -- --apply "$bypass"
expect 0 "bypass actor with --allow-bypass, --apply" "PUT orgs/SchoolEngine/rulesets/1" -- --apply --allow-bypass "$bypass"
bypass_case() {
  local want=$1 label=$2 actor=$3 write=-
  [[ "$want" -ne 0 ]] || write="PUT orgs/SchoolEngine/rulesets/1"
  expect "$want" "$label" "$write" -- --apply --allow-bypass "$(ruleset ".bypass_actors = [$actor]" actor.json)"
}
for id in 0 '"0"' '""' -5 1.5 null; do
  bypass_case 1 "Integration with actor_id $id refused, even with --allow-bypass" \
    "{\"actor_id\": $id, \"actor_type\": \"Integration\", \"bypass_mode\": \"always\"}"
done
bypass_case 1 "Team without actor_id refused" '{"actor_type": "Team", "bypass_mode": "pull_request"}'
bypass_case 1 "RepositoryRole with actor_id 0 refused" '{"actor_id": 0, "actor_type": "RepositoryRole", "bypass_mode": "always"}'
bypass_case 1 "User with a string actor_id refused" '{"actor_id": "42", "actor_type": "User", "bypass_mode": "always"}'
bypass_case 1 "DeployKey with an actor_id refused (null expected)" '{"actor_id": 3, "actor_type": "DeployKey", "bypass_mode": "always"}'
bypass_case 1 "unknown actor type refused" '{"actor_id": 3, "actor_type": "Robot", "bypass_mode": "always"}'
bypass_case 0 "DeployKey with actor_id null accepted" '{"actor_id": null, "actor_type": "DeployKey", "bypass_mode": "always"}'
bypass_case 0 "OrganizationAdmin (actor_id 1, ignored by the API) accepted" '{"actor_id": 1, "actor_type": "OrganizationAdmin", "bypass_mode": "always"}'
bypass_case 0 "Team with a positive integer id accepted" '{"actor_id": 7, "actor_type": "Team", "bypass_mode": "pull_request"}'
repo_placeholder=$(repo_ruleset '.bypass_actors = [{"actor_id": 0, "actor_type": "Integration", "bypass_mode": "always"}]' repo-placeholder.json)
expect 1 "repository ruleset with a placeholder bypass actor" \
  - -- --apply --allow-bypass --repo SchoolEngine/contracts "$repo_placeholder"
expect 2 "--repo with a .. segment" - -- --repo "SchoolEngine/.." "$root/rulesets/protect-develop.json"
expect 2 "--repo with a . segment" - -- --repo "./contracts" "$root/rulesets/protect-develop.json"
expect 2 "malformed --repo" - -- --repo "SchoolEngine" "$root/rulesets/protect-develop.json"
expect 2 "unknown option" - -- --force "$root/rulesets/protect-develop.json"

echo "== Repository rulesets (--repo)"
same=$(repo_ruleset '.' repo-same.json)
expect 0 "repository file matches live" - -- --repo SchoolEngine/contracts "$same"
creation=$(repo_ruleset '.rules += [{"type": "creation"}]' repo-creation.json)
expect 0 "repository file differs: dry-run" - -- --repo SchoolEngine/contracts "$creation"
expect 0 "repository file differs, --apply: PUT on the repository ruleset" \
  "PUT repos/SchoolEngine/contracts/rulesets/2" -- --apply --repo SchoolEngine/contracts "$creation"
expect 0 "repository ruleset unknown, --apply: POST on the repository" \
  "POST repos/SchoolEngine/contracts/rulesets" -- --apply --repo SchoolEngine/contracts "$(repo_ruleset '.name = "other"' repo-new.json)"

if [[ "$failures" -gt 0 ]]; then
  echo "$failures case(s) failed."
  exit 1
fi
echo "All cases passed."

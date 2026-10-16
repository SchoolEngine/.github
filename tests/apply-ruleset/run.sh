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
expect 1 "not a ruleset" - -- "$(ruleset '{name}' notruleset.json)"
bypass=$(ruleset '.bypass_actors = [{"actor_id": 15368, "actor_type": "Integration", "bypass_mode": "always"}]' bypass.json)
expect 1 "bypass actor without --allow-bypass" - -- --apply "$bypass"
expect 0 "bypass actor with --allow-bypass, --apply" "PUT orgs/SchoolEngine/rulesets/1" -- --apply --allow-bypass "$bypass"
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

#!/usr/bin/env bash
# Apply a SchoolEngine ruleset from its JSON file: an organisation ruleset
# (rulesets/ of this repository) or, with --repo, a repository ruleset (for
# example rulesets/ of SchoolEngine/contracts).
#
# Usage: scripts/apply-ruleset.sh [--apply] [--allow-bypass] [--repo <owner>/<repo>] <NAME.json>
#
# Dry-run by default: prints the diff between the live ruleset and the file and
# changes nothing. With --apply, replaces the live ruleset (PUT) when it differs,
# or creates it (POST) when no ruleset of that name exists. Running it twice is
# a no-op.
# The file must declare `bypass_actors` explicitly (`[]` for none): without the
# key, a PUT would keep the live bypass list and the file would no longer
# describe the ruleset. A file that declares bypass actors is refused unless
# --allow-bypass is given; the actors are printed in every case. A bypass
# actor without a valid actor_id for its type is always refused.
# Requires gh (authenticated as an organisation owner or repository admin) and jq.
set -euo pipefail

ORG="SchoolEngine"
KEYS='{name, target, enforcement, bypass_actors, conditions, rules}'
USAGE="usage: scripts/apply-ruleset.sh [--apply] [--allow-bypass] [--repo <owner>/<repo>] <NAME.json>"

apply=false
allow_bypass=false
repo=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) apply=true; shift ;;
    --allow-bypass) allow_bypass=true; shift ;;
    --repo) repo="${2:?$USAGE}"; shift 2 ;;
    -*) echo "$USAGE" >&2; exit 2 ;;
    *) break ;;
  esac
done
file="${1:?$USAGE}"

if [[ -n "$repo" ]]; then
  if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || "/$repo/" == */./* || "/$repo/" == */../* ]]; then
    echo "Refused: --repo must be <owner>/<repo>, got '$repo'." >&2
    exit 2
  fi
  scope="repos/$repo/rulesets"
  # Only the repository's own rulesets: never an inherited organisation one.
  list="$scope?includes_parents=false"
  where="repository $repo"
else
  scope="orgs/$ORG/rulesets"
  list="$scope"
  where="organisation $ORG"
fi

if ! jq -e 'type == "object" and has("name") and has("target") and has("rules")' "$file" >/dev/null; then
  echo "Refused: $file is not a ruleset (name, target and rules are required)." >&2
  exit 1
fi
if ! jq -e 'has("bypass_actors")' "$file" >/dev/null; then
  echo "Refused: $file has no bypass_actors key. Declare it, [] for none: without it the live bypass list would be kept." >&2
  exit 1
fi
if ! jq -e '(.bypass_actors | type) == "array"' "$file" >/dev/null; then
  echo "Refused: $file has a bypass_actors that is not an array ($(jq -r '.bypass_actors | type' "$file")): use [] for none." >&2
  exit 1
fi

# Bypass actors as the REST API defines them: Integration, RepositoryRole,
# Team and User need a real id (a positive integer: a placeholder such as 0,
# "0", "" or a negative value is refused, even with --allow-bypass, since the
# API may resolve it to an actor nobody chose); OrganizationAdmin ignores the
# id (GitHub returns 1); DeployKey takes null. Any other type is refused.
invalid="$(jq -r '[.bypass_actors[]? | select(
    if (.actor_type | IN("Integration", "RepositoryRole", "Team", "User")) then
      (.actor_id | (type == "number" and . > 0 and . == floor)) | not
    elif .actor_type == "OrganizationAdmin" then false
    elif .actor_type == "DeployKey" then .actor_id != null
    else true end)
  | "\(.actor_type // "?") \(.actor_id | tojson)"] | join(", ")' "$file")"
if [[ -n "$invalid" ]]; then
  echo "Refused: $file has bypass actor(s) without a valid actor_id for their type: $invalid." >&2
  exit 1
fi

bypass_count="$(jq '.bypass_actors | length' "$file")"
if [[ "$bypass_count" != "0" ]]; then
  echo "$file declares $bypass_count bypass actor(s):"
  jq -r '.bypass_actors[] | "  \(.actor_type) \(.actor_id // "-") (\(.bypass_mode))"' "$file"
  if ! $allow_bypass; then
    echo "Refused: bypass actors need --allow-bypass (protect-develop has none by design)." >&2
    exit 1
  fi
fi

name="$(jq -r '.name' "$file")"
id="$(gh api "$list" --paginate | jq -r --arg name "$name" '.[] | select(.name == $name) | .id')"

desired="$(mktemp)"
live="$(mktemp)"
trap 'rm -f "$desired" "$live"' EXIT
jq -S "$KEYS" "$file" > "$desired"

if [[ -z "$id" ]]; then
  echo "No live ruleset named '$name' in $where: it would be created."
  if $apply; then
    gh api -X POST "$scope" --input "$file" --jq '"Created ruleset \(.id)"'
  fi
  exit 0
fi

gh api "$scope/$id" | jq -S "$KEYS" > "$live"
if diff -u --label "live ($id)" --label "$file" "$live" "$desired"; then
  echo "Ruleset '$name' ($id) of $where already matches $file: nothing to do."
  exit 0
fi

if $apply; then
  gh api -X PUT "$scope/$id" --input "$file" --jq '"Updated ruleset \(.id) at \(.updated_at)"'
else
  echo "Dry-run: nothing changed. Re-run with --apply to update ruleset $id of $where."
fi

#!/usr/bin/env bash
# Apply an organisation ruleset of SchoolEngine from its JSON file in rulesets/.
#
# Usage: scripts/apply-ruleset.sh [--apply] <rulesets/NAME.json>
#
# Dry-run by default: prints the diff between the live ruleset and the file and
# changes nothing. With --apply, replaces the live ruleset (PUT) when it differs,
# or creates it (POST) when no ruleset of that name exists. Running it twice is
# a no-op. It refuses any file that declares a bypass actor.
# Requires gh (authenticated as an organisation owner) and jq.
set -euo pipefail

ORG="SchoolEngine"
KEYS='{name, target, enforcement, bypass_actors, conditions, rules}'

apply=false
if [[ "${1:-}" == "--apply" ]]; then
  apply=true
  shift
fi
file="${1:?usage: scripts/apply-ruleset.sh [--apply] <rulesets/NAME.json>}"

if [[ "$(jq '.bypass_actors | length' "$file")" != "0" ]]; then
  echo "Refused: $file declares bypass actors. protect-develop has none by design." >&2
  exit 1
fi

name="$(jq -r '.name' "$file")"
id="$(gh api "orgs/$ORG/rulesets" --paginate --jq ".[] | select(.name == \"$name\") | .id")"

desired="$(mktemp)"
live="$(mktemp)"
trap 'rm -f "$desired" "$live"' EXIT
jq -S "$KEYS" "$file" > "$desired"

if [[ -z "$id" ]]; then
  echo "No live ruleset named '$name' in $ORG: it would be created."
  if $apply; then
    gh api -X POST "orgs/$ORG/rulesets" --input "$file" --jq '"Created ruleset \(.id)"'
  fi
  exit 0
fi

gh api "orgs/$ORG/rulesets/$id" | jq -S "$KEYS" > "$live"
if diff -u --label "live ($id)" --label "$file" "$live" "$desired"; then
  echo "Ruleset '$name' ($id) already matches $file: nothing to do."
  exit 0
fi

if $apply; then
  gh api -X PUT "orgs/$ORG/rulesets/$id" --input "$file" --jq '"Updated ruleset \(.id) at \(.updated_at)"'
else
  echo "Dry-run: nothing changed. Re-run with --apply to update ruleset $id."
fi

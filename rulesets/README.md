# Rulesets

Organisation rulesets of SchoolEngine, kept as code. The JSON file is the source of truth: the live ruleset must always match it.

| File | Ruleset | What it enforces |
|---|---|---|
| `protect-develop.json` | `protect-develop` (id 25146431) | Default branch of every repository: no deletion, no force-push, linear history, PR required (squash only, review threads resolved, stale approvals dismissed), required check `Quality Gate` (GitHub Actions, integration id 15368, branch not required to be up to date). No bypass actor. |

The file holds only the fields accepted by the API (`name`, `target`, `enforcement`, `bypass_actors`, `conditions`, `rules`): no `id`, timestamps, `_links`, `node_id` or `source`. It can be re-imported as is, with `PUT` on the existing ruleset or `POST` on a new organisation.

## Changing a ruleset

1. **Change the JSON in a pull request first**, linked to an issue, and get it reviewed. Never change the ruleset in the GitHub UI.
2. After the merge, compare the file with the live ruleset (dry-run, changes nothing):

   ```bash
   scripts/apply-ruleset.sh rulesets/protect-develop.json
   ```

3. Apply it (organisation owner only):

   ```bash
   scripts/apply-ruleset.sh --apply rulesets/protect-develop.json
   ```

   The script is idempotent (a second run reports nothing to do) and refuses any file that declares a bypass actor. The equivalent raw call is `gh api -X PUT orgs/SchoolEngine/rulesets/25146431 --input rulesets/protect-develop.json`.

4. Check the result on one repository: `gh api repos/SchoolEngine/backend/rules/branches/develop`.

If the live ruleset was changed outside this process, export it back (`gh api orgs/SchoolEngine/rulesets/25146431 | jq '{name, target, enforcement, bypass_actors, conditions, rules}'`) and open a PR so the file matches again.

## Why `strict_required_status_checks_policy` is false

A strict policy forces every branch to be up to date with `develop` before merging, so each merge triggers a rebase and a new CI run on every open PR. With a single developer and squash merges, that cost buys little. Switch it to `true` in a PR if several people start merging in parallel.

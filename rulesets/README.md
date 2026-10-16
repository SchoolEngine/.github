# Rulesets

Organisation rulesets of SchoolEngine, kept as code. The JSON file is the source of truth: the live ruleset must always match it.

| File | Ruleset | What it enforces |
|---|---|---|
| `protect-develop.json` | `protect-develop` (id 25146431) | Default branch of every repository: no deletion, no force-push, linear history, PR required (squash only, review threads resolved, stale approvals dismissed), required check `Quality Gate` (GitHub Actions, integration id 15368, branch required to be up to date with `develop`). No bypass actor. |

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

   The script is idempotent (a second run reports nothing to do). It refuses a file without a `bypass_actors` key (`[]` for none: without the key, a `PUT` keeps the live bypass list and the file stops describing the ruleset), and a file that declares bypass actors unless `--allow-bypass` is given (`protect-develop` has none by design). The equivalent raw call is `gh api -X PUT orgs/SchoolEngine/rulesets/25146431 --input rulesets/protect-develop.json`.

4. Check the result on one repository: `gh api repos/SchoolEngine/backend/rules/branches/develop`.

If the live ruleset was changed outside this process, export it back (`gh api orgs/SchoolEngine/rulesets/25146431 | jq '{name, target, enforcement, bypass_actors, conditions, rules}'`) and open a PR so the file matches again.

## Repository rulesets

A repository keeps its own rulesets as code in its `rulesets/` folder (for example `protect-release-tags` in `SchoolEngine/contracts`). The same script handles them with `--repo`, run from a checkout of this repository (repository administrator only for `--apply`):

```bash
scripts/apply-ruleset.sh --repo SchoolEngine/contracts ../contracts/rulesets/protect-release-tags.json
scripts/apply-ruleset.sh --apply --repo SchoolEngine/contracts ../contracts/rulesets/protect-release-tags.json
```

It then reads `repos/<owner>/<repo>/rulesets?includes_parents=false` (never an inherited organisation ruleset), and updates `repos/<owner>/<repo>/rulesets/<id>` or creates the ruleset on the repository. The same rules apply: dry-run by default, `bypass_actors` required, `--allow-bypass` for a file that declares bypass actors.

The script is tested without network by `tests/apply-ruleset/run.sh` (a `gh` stub).

## Why `strict_required_status_checks_policy` is true

A strict policy only lets a PR merge when its branch contains the tip of `develop` and `Quality Gate` passed on that state. Without it, `Quality Gate` proves the branch is green, not that the result of the merge is: a PR opened before a new CI rule can be merged without ever meeting it. That happened in `parent-web`, where a `CLAUDE.md` PR based on an old `develop` never ran the newer `Format check` and turned `develop` red for every PR (SchoolEngine/parent-web#12). Decided by Céline on 2026-10-16 (SchoolEngine/.github#19).

The cost: after every merge, the other open PRs of the repository are out of date and must be updated before they can merge, which runs their CI again.

- Use the **Update branch** button of the PR, or `gh pr update-branch <n>` (`--rebase` to rebase instead of merging `develop` in; both are fine, the PR is squashed anyway).
- **Dependabot PRs are rebased by Dependabot itself**: comment `@dependabot rebase` on the PR (it also rebases on its own when the PR conflicts). Do not use Update branch on them: once someone else pushes to a Dependabot branch, Dependabot stops updating that PR.

## Enabling the Gate integrity check

`Gate integrity` (SchoolEngine/.github#22, [CI.md](../CI.md#gate-integrity)) is not in `protect-develop.json` yet: it is added by a separate **activation PR**, applied right after its merge. A required check that a repository never reports blocks every merge there, and a `pull_request_target` workflow only runs once it is on the default branch, so the order is fixed:

1. **Rollout.** In every repository, a PR copies `.github/workflows/gate-integrity.yml` and `.github/scripts/gate-integrity.sh` from this repository unchanged. That PR gets no `Gate integrity` run (the workflow is not on `develop` yet).
2. **Canary.** In every repository, a trivial PR (a typo fix, for example) must show `Gate integrity` green, and a deliberately weakened draft PR (a job removed from the gate's `needs:`) must show it red; close the draft. Check that every repository has both files on `develop` (each line must say `ok`):

   ```bash
   for r in $(gh repo list SchoolEngine --no-archived --json name --jq '.[].name'); do
     for f in .github/workflows/gate-integrity.yml .github/scripts/gate-integrity.sh; do
       gh api "repos/SchoolEngine/$r/contents/$f?ref=develop" --silent 2>/dev/null \
         && echo "ok      $r $f" || echo "MISSING $r $f"
     done
   done
   ```

3. **Activation PR** in this repository: adds `{"context": "Gate integrity", "integration_id": 15368}` to the required checks of `protect-develop.json`. After its merge, an organisation owner applies it; the dry-run must show only the added check:

   ```bash
   scripts/apply-ruleset.sh rulesets/protect-develop.json
   scripts/apply-ruleset.sh --apply rulesets/protect-develop.json
   ```

4. **Check** on one repository: `gh api repos/SchoolEngine/backend/rules/branches/develop --jq '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks'` lists both checks.
5. **Open PRs** opened before the activation have no `Gate integrity` run on their head commit: use **Update branch** (or push a commit, or edit the PR body) to trigger it.

**New repositories** get `gate-integrity.yml` and the checker in their scaffold, before their first PR: under the ruleset, a repository without them cannot merge anything.

**Break-glass** (the check is broken everywhere, for example a GitHub change to `pull_request_target`): an organisation owner removes the check from the live ruleset through the API, then records it in a PR so the file matches again:

```bash
jq '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks)
    |= map(select(.context != "Gate integrity"))' rulesets/protect-develop.json > /tmp/protect-develop.json
scripts/apply-ruleset.sh --apply /tmp/protect-develop.json
```

The PR that fixes the check then restores the entry, and it is applied again after its merge.

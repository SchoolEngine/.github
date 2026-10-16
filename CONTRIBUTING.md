# Contributing to SchoolEngine

These rules apply to every SchoolEngine repository. A repository's own `CLAUDE.md` or README may add stricter rules; it never relaxes these ones. The normative reference is the founding specification (§25 to §28, §37, §38).

## Branches

- `develop` is the default branch, the only long-lived branch and the starting point of every branch. There is no `main`.
- `develop` is protected by the organization ruleset `protect-develop`: pull request required, squash only, linear history, no force-push, no deletion, review threads resolved, no bypass (owners included).
- Never commit directly to `develop`, not even a typo.

## Workflow

1. **Issue first.** Nothing starts without an issue opened with one of the forms (feature, bug, tech debt, technical decision, epic). A development ticket is a sub-issue of its lot epic in `SchoolEngine/architecture`. It is ready only when it meets the Definition of Ready (spec §37): context, verifiable acceptance criteria, contract impact identified, dependencies resolved, reasonable size.
2. **Dedicated worktree.** Several people and agents work in parallel: each ticket gets its own worktree, never the shared checkout.

   ```bash
   git fetch origin
   git worktree add ../.worktrees/<repo>/<issue> -b <type>/<issue>-<description> origin/develop
   ```

3. **Branch naming:** `<type>/<issue>-<short-description>`, in English, lowercase, words separated by hyphens. The issue number is mandatory.

   | Type | Use |
   |---|---|
   | `feature` | New behavior |
   | `fix` | Bug fix |
   | `refactor` | Restructuring without behavior change |
   | `chore` | Tooling, dependencies, configuration |
   | `ci` | CI workflows and their templates |
   | `docs` | Documentation only |
   | `test` | Tests only |

4. **Commits:** [Conventional Commits](https://www.conventionalcommits.org/), in English: `<type>(<scope>): <imperative description> (#<issue>)`. Types: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `perf`, `ci`. The scope is the module or domain touched. The body explains why, never how.
5. **Pull request** against `develop`, using the template: `Closes #<issue>`, context, changes, what to review first, contract impact (none, additive, breaking) and the Definition of Done checklist. Its title follows the commit format and becomes the squash message. Target size: under ~400 diff lines.
6. **CI:** the `Quality Gate` check (format, lint, types, tests, gitleaks, osv-scanner, contract) must be green. A red CI is never bypassed: fix the cause, never the test or the threshold.
   - The `Gate integrity` check must be green too. A PR that changes the gate itself (removes a job, changes a common job, the gate, a workflow or the workflow-level settings of `ci.yml`, loosens the gitleaks configuration) is a **gate change**: its body has a `## Gate change` section with the justification, and an approver other than the author applies the `gate-change-approved` label after review (new commits remove it). It also needs the double agent review and Céline's explicit approval. Details: [CI.md](CI.md#gate-integrity).
   - Every ignore (`osv-scanner.toml`, `.gitleaksignore`, `.gitleaks.toml` allowlist) carries a justification and an expiry date at most 180 days ahead ([CI.md](CI.md#ignore-files)).
7. **Merge:** squash and merge only, and only with Céline's explicit approval. Nobody merges on their own initiative.
8. **Cleanup:** the branch is deleted on merge; remove the local branch and the worktree.

## Labels

Type: `feature`, `bug`, `tech-debt`, `security`, `docs`, `test`. State: `blocked`, `needs-info`, `breaking-change-approved`. Other: `epic`, `accessibility`, `privacy`. GitHub Actions is case-sensitive on labels: never create a duplicate with a different casing.

## Contract changes

An API change is never local: a pull request in `contracts` first, then the release of the generated clients, then one pull request per impacted consumer. Never hand-write an API type, model or path: everything comes from the generated clients. A breaking change requires the `breaking-change-approved` label and a prior explicit decision.

## Data and secrets

- No secret in git, ever, not even temporarily.
- No real user data outside production: local and staging use synthetic data only.
- No personal data in logs, issues, pull requests or screenshots.
- Install the [gitleaks](https://github.com/gitleaks/gitleaks) pre-commit hook (recommended, not mandatory) to catch a secret before it is committed. The `Quality Gate` runs gitleaks and osv-scanner (dependency audit) on every pull request regardless, and a finding blocks the merge.

## Security

Never report a vulnerability in a regular issue. See [SECURITY.md](SECURITY.md).

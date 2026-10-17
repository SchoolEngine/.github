# CI of the SchoolEngine repositories

Every SchoolEngine repository owns one workflow, `.github/workflows/ci.yml`, copied from a template of this repository. There is no reusable workflow: a repository's CI is readable in one file and changes through a pull request of that repository. Security tool choices: ADR-014 (`SchoolEngine/architecture`).

## Templates

| Template | For | Jobs on top of the common ones |
|---|---|---|
| [`ci-common`](workflow-templates/ci-common.yml) | Docs and configuration repositories (`architecture`, `.github`) | none |
| [`ci-node`](workflow-templates/ci-node.yml) | pnpm repositories (`backend`, `parent-web`, `admin-web`) | `node`: frozen install, format check (Prettier), lint, typecheck, tests with a coverage floor (`COVERAGE_MIN`: 80 % for `backend`, 70 % for `parent-web` and `admin-web`), build |
| [`ci-flutter`](workflow-templates/ci-flutter.yml) | `mobile-app` | `flutter`: pinned SDK (sha256 verified), enforced lockfile, `dart format --set-exit-if-changed`, `flutter analyze`, `flutter test --coverage`, coverage floor 70 % |
| [`ci-openapi`](workflow-templates/ci-openapi.yml) | `contracts` | `openapi-lint` (Spectral 6.16.3 standalone binary, sha256 verified, rule set `.spectral.yaml` from `templates/openapi/`, warnings block), `oasdiff` (breaking changes against the base branch), `generation-drift` (`git status` must stay clean after regeneration) |
| [`ci-ansible`](workflow-templates/ci-ansible.yml) | `infrastructure` | `ansible`: pinned ansible-core and ansible-lint, `--syntax-check` of every playbook; `sops`: every `*.sops.*` file is encrypted |

Common jobs, in every template:

| Job | Display name | Blocks on |
|---|---|---|
| `pr-conventions` | PR title and linked issue | title not in Conventional Commits; no `Closes #n` (or Fixes/Resolves, or `owner/repo#n`) in the body |
| `gitleaks` | Secrets (gitleaks) | any secret in the commits of the PR (`gitleaks git --redact` on `base..head`) |
| `actionlint` | Workflows (actionlint) | any actionlint or shellcheck finding in the workflows |
| `lint-yaml-markdown` | YAML and Markdown lint | yamllint (`--strict`) or markdownlint finding |
| `osv-scanner` | Vulnerable dependencies (osv-scanner) | a high or critical vulnerability (CVSS 7.0 or more), or one without a score, in a committed lockfile |
| `quality-gate` | **Quality Gate** | any job above that did not succeed |

Next to `ci.yml`, every repository has `.github/workflows/gate-integrity.yml` ([template](workflow-templates/gate-integrity.yml)), the `Gate integrity` check: see [Gate integrity](#gate-integrity).

Placeholders that a scaffold ticket must fill are marked `TODO(scaffold)` in the templates. They fail closed: an unfilled template is red, never green on nothing.

## Using a template

1. In the repository, open **Actions > New workflow**: the templates are listed in the section of workflows created by SchoolEngine. If they are not shown, copy the file by hand: `workflow-templates/ci-<variant>.yml` to `.github/workflows/ci.yml`.
2. Copy `templates/lint/.yamllint.yml` and `templates/lint/.markdownlint-cli2.yaml` to the repository root (and, for `contracts`, `templates/openapi/.spectral.yaml`). The lint jobs refuse to run without them.
   For a pnpm repository, pin pnpm in the `packageManager` field of `package.json` to a major that Dependabot supports (GitHub documents pnpm v7 to v10; `pnpm@10.34.6` on 2026-10-15).
   For a pnpm repository, also define the scripts the `node` job calls (`format:check` = `prettier --check .`, `lint`, `typecheck`, `test:coverage`, `build`) and keep YAML and Markdown out of Prettier (see [Formatting](#formatting)).
3. Fill the `TODO(scaffold)` placeholders, open the pull request, and check that every job, then `Quality Gate`, is green.

The templates are only offered from the default branch (`develop`) of this repository, once merged.

## The shape every `ci.yml` keeps

- `name: CI`.
- `on: pull_request` with types `[opened, synchronize, reopened]` only. No `edited`: **after editing the PR title or body, push a commit or re-run the `PR title and linked issue` job** (it reads the title and body live from the API, so a re-run sees the new text). Same for a label added after the last run (`breaking-change-approved` in `ci-openapi`). No `workflow_dispatch`: the fork guard would skip every job and the gate would fail.
- `permissions: contents: read` at workflow level. A job that needs more declares it at job level, minimal (`pull-requests: read` to read the PR title, body and labels). The organisation enforces a read-only default `GITHUB_TOKEN`.
- `concurrency` group `${{ github.workflow }}-${{ github.head_ref || github.ref_name }}` with `cancel-in-progress: true`.
- Fork guard on every job except the gate: `if: github.event.pull_request.head.repo.full_name == github.repository`. A fork PR skips every job and fails the gate: it never runs code with the repository's token.
- `timeout-minutes` on every job.
- `actions/checkout` always with `persist-credentials: false`.
- Third-party actions pinned by full commit SHA with a `# owner/action@vX.Y.Z` comment (enforced by the organisation). No wrapper action for the security tools.
- Tool versions pinned in the workflow `env:` block, one place per template, each with the sha256 of its linux amd64 release asset (`GITLEAKS_SHA256`, `ACTIONLINT_SHA256`, `OSV_SCANNER_SHA256`, `OASDIFF_SHA256`, `YQ_SHA256`, `SPECTRAL_SHA256`, `FLUTTER_SHA256`). The download is checked against that pinned value, never against a checksum file of the same release (an attacker who can replace an asset can replace the checksum file next to it).
- PR title, body and labels never appear in a `${{ }}` expression inside `run:` (script injection): they are fetched by the script and kept in shell variables.

## The Quality Gate

`Quality Gate` is the **single required check** of `develop`. It is required by the organisation ruleset `protect-develop` (kept as code in [`rulesets/protect-develop.json`](rulesets/protect-develop.json), see [`rulesets/README.md`](rulesets/README.md)), which names the check and its source (GitHub Actions, integration id 15368), not the workflow: every repository must produce a check called exactly `Quality Gate`, or none of its PRs can be merged. The policy is **strict**: a PR merges only when its branch is up to date with `develop` and `Quality Gate` passed on that state, so a PR older than a new CI rule cannot skip it (SchoolEngine/parent-web#12). After each merge, update the other open PRs before merging them: the **Update branch** button or `gh pr update-branch <n>`. Dependabot PRs are rebased by Dependabot itself (`@dependabot rebase`); never push to them. Details in [`rulesets/README.md`](rulesets/README.md#why-strict_required_status_checks_policy-is-true).

Rules, all learned on TheOpenMusicBox:

- **Never rename** the `quality-gate` job or its name `Quality Gate`. A required check that no longer reports blocks every PR; a renamed one silently stops being required.
- **Its `if:` is exactly `${{ !cancelled() }}`, nothing else.** A skipped required check counts as **passing**: any extra condition that can be false (a fork guard, an event test) turns a red PR into a mergeable one. `always()` is not used either: it keeps the job alive on a cancelled run.
- It `needs:` **every other job** and fails unless every needed result is `success`. A `skipped` or `cancelled` job fails the gate.
- A cancelled run leaves the gate `cancelled`, which blocks the merge: re-run the workflow.
- **Adding a job**: add it under `jobs:` with the fork guard and a `timeout-minutes`, then add its id to the `needs:` list of `quality-gate`. Nothing else: the gate reads the results of `needs` generically. A job missing from `needs:` does not block anything.
- Removing a job: remove it from `needs:` in the same PR. It is a gate change ([Gate integrity](#gate-integrity)).

## Gate integrity

`Quality Gate` lives in each PR's own `ci.yml`, and `protect-develop` requires no approving review: a PR can weaken the gate that judges it. `Gate integrity` is the detective control decided by Céline on 2026-10-16 (SchoolEngine/.github#22) instead of mandatory approvals. It becomes the **second required check** of `protect-develop` through a separate activation PR, once every repository has it ([`rulesets/README.md`](rulesets/README.md#enabling-the-gate-integrity-check)).

### How it runs, and why the PR it judges cannot rewrite it

- It is a separate workflow, `.github/workflows/gate-integrity.yml`, on **`pull_request_target`**. GitHub takes that workflow file, and the checker `.github/scripts/gate-integrity.sh` it runs, from the repository's **default branch** (`develop`), never from the PR. GitHub's documentation used to say "the PR base branch"; since our PRs target `develop`, the default branch, both readings give the same file. A change to either file only takes effect after its own merge, and is itself a gate change.
- The PR is **data only**. The job checks out the default branch (no `ref:`), fetches the merge commit GitHub computed (`refs/pull/<n>/merge`) as git objects, and reads the files it needs with `git cat-file`: nothing from the PR is checked out, built, installed or executed. The base of the comparison is the first parent of that merge commit (the tip of `develop`).
- No PR field is interpolated into a script: only the PR number and SHAs go through `env:`; the PR (body, author) is saved as a JSON file read by `jq` and Python. Text from the PR is escaped in annotations and fenced by `::stop-commands::` markers in diffs, so it cannot issue workflow commands.
- `permissions: {}` at the top, `contents: read` and `pull-requests: read` for the job, no secret. Actions pinned by SHA, yq by version and sha256; `python3`, `jq`, `git` and `gh` come from the runner image. `tests/gate-integrity/run.sh` asserts these invariants on the workflow file and that this repository's copy is the template.
- It re-runs on new commits and when the title or body is edited (`opened`, `synchronize`, `reopened`, `edited`). It runs on fork PRs too (nothing is executed).

### What it checks

| Finding | With a `## Gate change` justification? |
|---|---|
| A common job missing from `ci.yml` (`pr-conventions`, `gitleaks`, `actionlint`, `lint-yaml-markdown`, `osv-scanner`), or `quality-gate` missing or renamed | refused |
| The gate's `if:` not exactly `${{ !cancelled() }}`; a job not in its `needs:`; `continue-on-error` anywhere in `ci.yml` | refused |
| In any workflow: more than one YAML document, duplicate keys in a mapping, a YAML anchor, alias or merge key; no top-level `permissions:`; a `shell` other than exactly `bash`, `sh`, `pwsh`, `powershell`, `python` or `cmd`; a job `name:` containing `${{`; a job named like a required check (`Quality Gate` outside `ci.yml`'s `quality-gate`, `Gate integrity` outside `gate-integrity.yml`'s `gate-integrity`) | refused |
| In any workflow but `gate-integrity.yml`: a `pull_request_target` or `workflow_run` trigger, or a `write` permission (`write-all` included) | refused |
| `ci.yml` `env:`: a `*_VERSION` that is not digits and dots, a version lower than on the base branch, a `*_SHA256` that is not 64 lowercase hex digits, a tool whose `*_VERSION` and `*_SHA256` do not change together | refused |
| `gate-integrity.yml` or the checker removed; an ignore without a valid justification and expiry ([Ignore files](#ignore-files)) | refused |
| A job of the base branch removed from `ci.yml`; the definition of a common job or of the gate changed (the gate's `needs:` aside, so adding a job passes) | gate change |
| `ci.yml` changed outside `jobs`: `name`, `on`, `permissions`, `defaults`, `concurrency`, or `env` except the `*_VERSION` / `*_SHA256` pins (a new `BASH_ENV` or a lowered `COVERAGE_MIN` is a gate change) | gate change |
| Any other workflow added or changed, `gate-integrity.yml` included; the checker changed; any file under `.github/actions/` added, changed or removed | gate change |
| `.gitleaks.toml` without `[extend] useDefault = true`, or with `disabledRules` | gate change |

**Action SHAs.** A changed SHA in `uses:` is ignored only in a PR opened by `dependabot[bot]`, and only when the action itself (`owner/repo`) is unchanged; in `gate-integrity.yml` it is never ignored. A person changing a SHA, or Dependabot bumping an action of `gate-integrity.yml`, makes a gate change: add the `## Gate change` section to the PR body (editing the body of a Dependabot PR is fine; pushing to its branch is not).

Changes to stack jobs (adding a job, a step, a stack job's commands) and matrices are not gate changes: matrix jobs get the matrix values appended in parentheses, so they never carry a required check's exact name.

### Approving a gate change

The checker only asks for a reason: the PR body has a `## Gate change` section whose text, **HTML comments removed entirely**, has at least 20 letters or digits. The approval itself is the **double agent review (code and security) recorded on the PR**, then Céline's explicit go to merge, as for every PR. There is no label and no human approver mechanism. The section is re-read when the body is edited: no re-run by hand is needed.

### Residual risks

It is a detective control with a narrow preventive core, not a guarantee:

- **Owners are trusted.** The PRs are opened by an organisation owner account and `protect-develop` requires 0 approvals: an owner can still change the ruleset or merge after a review that missed something. The control makes a weakening visible and attributable.
- **A new or changed workflow runs before review.** A workflow added on `pull_request` runs on the PR's own commits as soon as they are pushed, before anyone reads it (read-only token, no secret, but it can report checks). `Gate integrity` flags it; reviewers read every workflow change before anything else.
- **Required checks are matched by name.** Other workflows of a PR can report checks; the checker refuses the reserved names, and reviewers confirm that `Gate integrity` and `Quality Gate` each appear once on the head commit.
- **After merge.** An approved change to `gate-integrity.yml` or the checker judges every later PR: the review of such a PR is the real control.
- **Not covered:** stack jobs made weaker while still succeeding (a test command that tests less), and files the checker does not read (a lint configuration, a `package.json` script). Those are for review.

### Rolling it out to a repository

One `ci(quality-gate)` PR per repository copies `.github/workflows/gate-integrity.yml` and `.github/scripts/gate-integrity.sh` from this repository unchanged. That PR gets no `Gate integrity` run (the workflow is not on `develop` yet); the next ones do. Canary, activation, break-glass and new repositories: [`rulesets/README.md`](rulesets/README.md#enabling-the-gate-integrity-check).

To change the checker: change it and its tests here (`tests/gate-integrity/run.sh`, run by the `scripts` job of this repository's `ci.yml`), then copy it into each repository in a PR justified as a gate change.

### Ignore files

Every ignore carries a justification of at least 20 letters or digits and an expiry date that is not past and at most **180 days** ahead (ADR-014). Renewing means a new justification and a new date, in a reviewed PR.

- `osv-scanner.toml` (any directory: osv-scanner reads the one next to each lockfile): each `[[IgnoredVulns]]` has `reason` and `ignoreUntil`; each `[[PackageOverrides]]` that ignores has `reason` and `effectiveUntil`. osv-scanner itself stops ignoring after the date; the check also refuses a past date.
- `.gitleaksignore`: each fingerprint is preceded by a comment `# <justification> expires: YYYY-MM-DD`. gitleaks has no expiry of its own, so the check fails once the date is past: remove the entry or renew it.
- `.gitleaks.toml`: extends the default rules (`[extend] useDefault = true`); each allowlist (top level or in a rule) has a `description` ending with `expires: YYYY-MM-DD`, enforced the same way.

```toml
[[allowlists]]
description = "Synthetic keys of the test fixtures, not secrets. expires: 2027-01-31"
paths = ['''tests/fixtures/keys/''']
```

An expired entry turns every PR of the repository red until it is removed or renewed: intended.

## Formatting

One formatter of record per file type, all blocking:

| Files | Tool | Job |
| --- | --- | --- |
| YAML | yamllint `--strict` (`.yamllint.yml`) | `lint-yaml-markdown` |
| Markdown | markdownlint-cli2 (`.markdownlint-cli2.yaml`) | `lint-yaml-markdown` |
| TypeScript, JavaScript, JSON, CSS, HTML (pnpm repositories) | Prettier, `pnpm run format:check` | `node` (`Format check`) |
| Dart | `dart format --set-exit-if-changed` | `flutter` (`Format`) |

In a pnpm repository, `.prettierignore` lists `*.md`, `*.yml` and `*.yaml` (plus the lockfile and build outputs). Prettier would otherwise judge them a second time with a different rule set: a Markdown file that markdownlint accepts can fail `Format check`, and Dependabot PRs, which rewrite `.github/` YAML, would fail on a rule nobody chose. In `parent-web` an unformatted `CLAUDE.md` merged from a branch older than the `node` job turned `develop` red for every PR (SchoolEngine/parent-web#12).

## Security rules (ADR-014)

- **A gitleaks finding means the secret is compromised**: it has already been pushed. Rotate it first, then remove it from the branch. `.gitleaksignore` and inline `gitleaks:allow` are used only for proven false positives, justified in the PR; `.gitleaksignore` entries and allowlists also carry an expiry date ([Ignore files](#ignore-files)).
- **osv-scanner** blocks on high and critical findings, and on findings without a severity score. Moderate and low findings are left to Dependabot alerts. A finding with no available fix may be ignored only in `osv-scanner.toml` (`[[IgnoredVulns]]` with `reason` and `ignoreUntil`), reviewed in the PR. `pnpm audit` is a local command, never a CI check.
- **Dependabot PRs** are exempt from the `Closes #n` check only (author `dependabot[bot]`); their `chore(deps): ...` titles pass the title check like any other.
- Before any mirror or migration of a repository, run `gitleaks git` on the whole history.

## Bumping a tool version

Versions downloaded in `run:` steps are not seen by Dependabot. To bump one: change the version **and its `*_SHA256`** in the `env:` block of the template here, then in each repository's `ci.yml`. Take the sha256 from the asset digest GitHub shows on the release page (or `gh release view`), cross-checked with a local `sha256sum` of the downloaded asset and, when the project publishes one, its checksum file (the Flutter value comes from the Flutter release index). A version bump with its sha256 is not a gate change; `Gate integrity` refuses a malformed version, a downgrade, and a version or sha256 changed alone. Actions in `uses:` are bumped by Dependabot (`github-actions` ecosystem), keeping the SHA and the version comment in sync.

## Runners: GitHub-hosted now, self-hosted later

Jobs run on `ubuntu-latest` until the self-hosted lanes exist (SchoolEngine/infrastructure#12, ADR-011). Each `runs-on:` carries a comment with its future value, `[self-hosted, Linux, X64, <lane>]`. The switch is a one-line change per job and does not touch the gate. Tools are installed by the jobs themselves (no reliance on the preinstalled software of the GitHub image, except `jq`, `curl`, `git`, `gh`, `shellcheck` and, for `Gate integrity`, `python3`), so the same file runs on a self-hosted lane, and later on Forgejo Actions.

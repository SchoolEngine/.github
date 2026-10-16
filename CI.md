# CI of the SchoolEngine repositories

Every SchoolEngine repository owns one workflow, `.github/workflows/ci.yml`, copied from a template of this repository. There is no reusable workflow: a repository's CI is readable in one file and changes through a pull request of that repository. Security tool choices: ADR-014 (`SchoolEngine/architecture`).

## Templates

| Template | For | Jobs on top of the common ones |
|---|---|---|
| [`ci-common`](workflow-templates/ci-common.yml) | Docs and configuration repositories (`architecture`, `.github`) | none |
| [`ci-node`](workflow-templates/ci-node.yml) | pnpm repositories (`backend`, `parent-web`, `admin-web`) | `node`: frozen install, format check (Prettier), lint, typecheck, tests with a coverage floor (`COVERAGE_MIN`: 80 % for `backend`, 70 % for `parent-web` and `admin-web`), build |
| [`ci-flutter`](workflow-templates/ci-flutter.yml) | `mobile-app` | `flutter`: pinned SDK (checksum verified), enforced lockfile, `dart format --set-exit-if-changed`, `flutter analyze`, `flutter test --coverage`, coverage floor 70 % |
| [`ci-openapi`](workflow-templates/ci-openapi.yml) | `contracts` | `openapi-lint` (Spectral 6.16.3 standalone binary, checksum verified, rule set `.spectral.yaml` from `templates/openapi/`, warnings block), `oasdiff` (breaking changes against the base branch), `generation-drift` (`git status` must stay clean after regeneration) |
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
- Tool versions pinned in the workflow `env:` block, one place per template. gitleaks, actionlint, osv-scanner and oasdiff come from their GitHub releases and are verified against the published checksum file before running; the Spectral binary against a pinned sha256 (its release publishes no checksum file; the value is the asset digest shown by GitHub); the Flutter SDK archive against the sha256 of the Flutter release index.
- PR title, body and labels never appear in a `${{ }}` expression inside `run:` (script injection): they are fetched by the script and kept in shell variables.

## The Quality Gate

`Quality Gate` is the **single required check** of `develop`. It is required by the organisation ruleset `protect-develop` (kept as code in [`rulesets/protect-develop.json`](rulesets/protect-develop.json), see [`rulesets/README.md`](rulesets/README.md)), which names the check and its source (GitHub Actions, integration id 15368), not the workflow: every repository must produce a check called exactly `Quality Gate`, or none of its PRs can be merged. The policy is **strict**: a PR merges only when its branch is up to date with `develop` and `Quality Gate` passed on that state, so a PR older than a new CI rule cannot skip it (SchoolEngine/parent-web#12). After each merge, update the other open PRs before merging them: the **Update branch** button or `gh pr update-branch <n>`. Dependabot PRs are rebased by Dependabot itself (`@dependabot rebase`); never push to them. Details in [`rulesets/README.md`](rulesets/README.md#why-strict_required_status_checks_policy-is-true).

Rules, all learned on TheOpenMusicBox:

- **Never rename** the `quality-gate` job or its name `Quality Gate`. A required check that no longer reports blocks every PR; a renamed one silently stops being required.
- **Its `if:` is exactly `${{ !cancelled() }}`, nothing else.** A skipped required check counts as **passing**: any extra condition that can be false (a fork guard, an event test) turns a red PR into a mergeable one. `always()` is not used either: it keeps the job alive on a cancelled run.
- It `needs:` **every other job** and fails unless every needed result is `success`. A `skipped` or `cancelled` job fails the gate.
- A cancelled run leaves the gate `cancelled`, which blocks the merge: re-run the workflow.
- **Adding a job**: add it under `jobs:` with the fork guard and a `timeout-minutes`, then add its id to the `needs:` list of `quality-gate`. Nothing else: the gate reads the results of `needs` generically. A job missing from `needs:` does not block anything.
- Removing a job: remove it from `needs:` in the same PR.

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

- **A gitleaks finding means the secret is compromised**: it has already been pushed. Rotate it first, then remove it from the branch. `.gitleaksignore` and inline `gitleaks:allow` are used only for proven false positives, justified in the PR.
- **osv-scanner** blocks on high and critical findings, and on findings without a severity score. Moderate and low findings are left to Dependabot alerts. A finding with no available fix may be ignored only in `osv-scanner.toml` (`[[IgnoredVulns]]` with `reason` and `ignoreUntil`), reviewed in the PR. `pnpm audit` is a local command, never a CI check.
- **Dependabot PRs** are exempt from the `Closes #n` check only (author `dependabot[bot]`); their `chore(deps): ...` titles pass the title check like any other.
- Before any mirror or migration of a repository, run `gitleaks git` on the whole history.

## Bumping a tool version

Versions downloaded in `run:` steps are not seen by Dependabot. To bump one: change the version (and, for Flutter and Spectral, the sha256: the Flutter release index, or the asset digest of the Spectral GitHub release) in the `env:` block of the template here, then in each repository's `ci.yml`. Actions in `uses:` are bumped by Dependabot (`github-actions` ecosystem), keeping the SHA and the version comment in sync.

## Runners: GitHub-hosted now, self-hosted later

Jobs run on `ubuntu-latest` until the self-hosted lanes exist (SchoolEngine/infrastructure#12, ADR-011). Each `runs-on:` carries a comment with its future value, `[self-hosted, Linux, X64, <lane>]`. The switch is a one-line change per job and does not touch the gate. Tools are installed by the jobs themselves (no reliance on the preinstalled software of the GitHub image, except `jq`, `curl` and `shellcheck`), so the same file runs on a self-hosted lane, and later on Forgejo Actions.

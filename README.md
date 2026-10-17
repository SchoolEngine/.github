# .github

Organization-level files of SchoolEngine.

| File | Purpose |
|---|---|
| `.github/ISSUE_TEMPLATE/` | Issue forms: feature, bug, tech debt, technical decision (ADR request), epic. Blank issues disabled; security reports routed to `SECURITY.md`. |
| `.github/PULL_REQUEST_TEMPLATE.md` | Pull request template: `Closes #`, context, changes, review priorities, contract impact, Definition of Done checklist. |
| `CONTRIBUTING.md` | Workflow and naming conventions shared by every repository. |
| `SECURITY.md` | Private vulnerability reporting procedure. |
| `CI.md` | Shape and rules of every repository's `ci.yml`, the `Quality Gate` contract, `Gate integrity`. |
| `workflow-templates/` | Organisation workflow templates `ci-common`, `ci-node`, `ci-flutter`, `ci-openapi`, `ci-ansible` and `gate-integrity` (Actions > New workflow). |
| `templates/lint/` | Default `.yamllint.yml` and `.markdownlint-cli2.yaml` copied to each repository root. |
| `templates/openapi/` | Default `.spectral.yaml` (extends `spectral:oas`) for the contracts repository. |
| `DEPENDABOT.md` | Dependency update rules and how each repository adopts its template. |
| `templates/dependabot/` | `dependabot.yml` templates: `common`, `node`, `flutter`, and the `container` entry. |
| `.github/workflows/ci.yml` | CI of this repository, from the `ci-common` template plus a `scripts` job (shellcheck, `tests/*/run.sh`): produces the `Quality Gate` check. |
| `.github/dependabot.yml` | Dependabot configuration of this repository, from the `common` template (`github-actions`). |
| `.yamllint.yml`, `.markdownlint-cli2.yaml` | Lint configuration of this repository, copies of `templates/lint/`. |
| `rulesets/` | Organisation rulesets as code (`protect-develop.json`: protection of every default branch, required `Quality Gate` check) and how to change them. |
| `workflow-templates/gate-integrity.yml`, `.github/workflows/gate-integrity.yml` | `Gate integrity` required check (`pull_request_target`, the PR is read as data): template and this repository's copy. |
| `.github/scripts/gate-integrity.sh` | Checker run by `Gate integrity`, copied into every repository; tests in `tests/gate-integrity/`, run by the `scripts` job of `ci.yml`. |
| `scripts/apply-ruleset.sh` | Compares a ruleset file with the live ruleset (dry-run by default) and applies it with `--apply`. |

## Inheritance by the other repositories

This repository is public, so GitHub applies these files as defaults to every SchoolEngine repository that does not define its own ([GitHub docs: creating a default community health file](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/creating-a-default-community-health-file)). A repository that defines its own `.github/ISSUE_TEMPLATE/` folder sees none of the default forms: override deliberately.

Being public, this repository must never hold anything confidential: no secret, no personal data, no internal roadmap or security posture.

Work tracking: <https://github.com/SoutienScolaireApp/docs/issues/11>

# .github

Organization-level files of SchoolEngine.

| File | Purpose |
|---|---|
| `.github/ISSUE_TEMPLATE/` | Issue forms: feature, bug, tech debt, technical decision (ADR request), epic. Blank issues disabled; security reports routed to `SECURITY.md`. |
| `.github/PULL_REQUEST_TEMPLATE.md` | Pull request template: `Closes #`, context, changes, review priorities, contract impact, Definition of Done checklist. |
| `CONTRIBUTING.md` | Workflow and naming conventions shared by every repository. |
| `SECURITY.md` | Private vulnerability reporting procedure. |

## Inheritance by the other repositories

GitHub only applies these files as defaults to the other repositories of the organization when this `.github` repository is **public** ([GitHub docs: creating a default community health file](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/creating-a-default-community-health-file)). This repository is currently **private**, so the defaults are **not** inherited.

Until that changes, the fallback is a copy per repository:

1. Copy `.github/ISSUE_TEMPLATE/` and `.github/PULL_REQUEST_TEMPLATE.md` into the repository's own `.github/` folder, and `CONTRIBUTING.md` and `SECURITY.md` to its root or `.github/` folder.
2. Keep the copies identical to this repository: a change here is propagated by a pull request in each repository.
3. A repository that defines its own `.github/ISSUE_TEMPLATE/` never sees any default form, even after this repository becomes public: override deliberately, file by file.

Work tracking: https://github.com/SoutienScolaireApp/docs/issues/11

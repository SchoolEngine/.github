# CLAUDE.md: `.github`

Rules for contributors and agents working in `SchoolEngine/.github`.

This repository holds the files every other SchoolEngine repository inherits or copies: community files, CI workflow templates, the Dependabot template and the organisation ruleset exported as code. **It is public**, so GitHub applies its community files as defaults to every SchoolEngine repository that has none of its own; for the same reason it never holds anything confidential (no secret, no personal data, no internal roadmap or security posture).

Normative references: founding specification (`FOUNDING-SPECIFICATION.md` in `SoutienScolaireApp/docs`) §25 to §27, §29, §37, §38; ADR-014 (security tooling) in `SchoolEngine/architecture/adr/`.

## Issue and pull request templates

- **Where**: `.github/ISSUE_TEMPLATE/` (forms: feature, bug, tech debt, technical decision, epic; blank issues disabled, `config.yml` routes security reports to `SECURITY.md`) and `.github/PULL_REQUEST_TEMPLATE.md`. `CONTRIBUTING.md` and `SECURITY.md` sit at the root.
- **Issue body structure**: Context, Problem, Expected behavior, Acceptance criteria, Technical notes, Dependencies, Definition of Done. Development forms also ask for the contract impact and the parent epic.
- **PR template**: `Closes #`, Context, Changes, Review first, Contract impact (none, additive, breaking), Definition of Done (§38).
- **Propagation**: inherited automatically by every repository without its own `.github/ISSUE_TEMPLATE/` (a repository that defines one sees **none** of the defaults). A template change is described in its PR and announced on the L0 epic (SchoolEngine/architecture#1) when it changes what contributors must write.
- In a form, a prefilled value ending with a space (a checkbox line `- [ ]` followed by a space) is a double-quoted string, never a `|` block (yamllint `trailing-spaces`).

## CI workflow templates

- **Where**: `workflow-templates/ci-{common,node,flutter,openapi,ansible}.yml` with their `*.properties.json`, the rules in `CI.md`, lint configurations in `templates/lint/` and the Spectral rule set in `templates/openapi/`.
- **Model**: every repository owns one `.github/workflows/ci.yml` **copied** from a template. There is no reusable workflow. Common jobs: `PR title and linked issue`, `Secrets (gitleaks)`, `Workflows (actionlint)`, `YAML and Markdown lint`, `Vulnerable dependencies (osv-scanner)`, aggregated by the single required check `Quality Gate`.
- **Gate rules**: the `quality-gate` job and its name `Quality Gate` are never renamed; its `if:` is exactly `${{ !cancelled() }}`; it `needs:` every other job and fails unless each one succeeded. A required job name is never renamed once required.
- **Workflow rules**: third-party actions pinned by full SHA with a version comment; explicit `permissions` (`contents: read` at workflow level, more only per job); `persist-credentials: false`; fork guard on every job but the gate; `timeout-minutes` everywhere; tool versions pinned in `env:` and verified against checksums; no `pull_request_target` without a documented need; PR text never interpolated in `run:`.
- **Propagation**: change the template and `CI.md` here, then open one PR in each consuming repository to update its `ci.yml`. Tool versions downloaded in `run:` are invisible to Dependabot and bumped by hand, here first.

## Dependabot template

- **Where**: `templates/dependabot/{common,node,flutter,container}.yml` and `DEPENDABOT.md`.
- Ecosystems: `github-actions` everywhere, `npm` for pnpm repositories, `pub` for `mobile-app`, `docker` where a `Containerfile` is built. Weekly on Monday, 7-day cooldown, minor and patch grouped, `chore(deps):` prefix, label `tech-debt`. The generated API clients are ignored (ADR-013, manual bump).
- **Propagation**: each repository copies its template into `.github/dependabot.yml` (CI ticket for `common`, scaffold ticket for its ecosystem); a template change is followed by one PR per repository.

## Ruleset export

- **Where**: `rulesets/protect-develop.json` is the code copy of the organisation ruleset `protect-develop` (PR required, squash only, linear history, no force-push or deletion, review threads resolved, required check `Quality Gate`, no bypass actor); `rulesets/README.md` and `scripts/apply-ruleset.sh`.
- **Change**: edit the JSON in a PR first, never in the GitHub UI; after the merge, `scripts/apply-ruleset.sh rulesets/protect-develop.json` (dry-run), then `--apply` (owner only). A live change made elsewhere is exported back to the file in a PR.

## Never here

This repository never contains nor calls an `add-to-project` workflow: nothing from SchoolEngine goes on the SoutienScolaireApp board. No Renovate configuration (Dependabot is the tool, ADR-014).

## Commands

```bash
yamllint --strict .
npx --yes markdownlint-cli2@0.23.3
actionlint
actionlint workflow-templates/*.yml   # CI only lints .github/workflows/
```

## CI (`.github/workflows/ci.yml`)

The `ci-common` template as is: the five common jobs and the required `Quality Gate` check. A new job goes into its `needs:`.

## Workflow

Shared rules: `CONTRIBUTING.md` and `CI.md` of `SchoolEngine/.github`. In short:

1. **Issue first**, from an organisation issue form, attached to its lot epic (see Task tracking).
2. **Dedicated worktree** per ticket, never the shared checkout:

   ```bash
   git fetch origin
   git worktree add ../.worktrees/engine-github/<issue> -b <type>/<issue>-<description> origin/develop
   ```

   Branch types: `feature`, `fix`, `refactor`, `chore`, `docs`, `test`, `ci`; English, lowercase, hyphens, issue number mandatory.
3. **Commits** in Conventional Commits, in English: `<type>(<scope>): <imperative description> (#<issue>)`, types `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `perf`, `ci`. The body explains why.
4. **Pull request** against `develop` with the template: `Closes #<issue>`, context, changes, what to review first, contract impact (none, additive, breaking). The title follows the commit format and becomes the squash message. About 400 diff lines at most.
5. **`develop` is protected** by the organisation ruleset `protect-develop`: PR required, squash only, linear history, no force-push, review threads resolved, no bypass, required check `Quality Gate`. A red gate is fixed at its cause, never by weakening a test, a rule or a threshold.
6. **Merge**: squash and merge only, and only with **Céline's explicit approval**. An agent never merges on its own initiative. Afterwards, delete the branch and remove the worktree.

Everything on GitHub is written in English. No secret in git, no real user data outside production. Never poll the GitHub API in a loop to follow CI.

## Task tracking (ADR-010)

Points are earned in `SoutienScolaireApp`, code is written in `SchoolEngine` (governance rule: ADR-010 in `SoutienScolaireApp/docs`).

- Every ticket of this repository is a **sub-issue of its lot epic** in `SchoolEngine/architecture` (lot L0: SchoolEngine/architecture#1). The epic links the lot card of `SoutienScolaireApp/docs` by URL; acceptance and points stay on that card.
- A ticket never carries the `contribution` label, `Points` or `Bénéficiaire`, and never goes on the SoutienScolaireApp board. This repository never contains nor calls an `add-to-project` workflow.
- Attach a new ticket to its epic with GraphQL (the `gh` CLI cannot):

  ```bash
  EPIC=$(gh issue view 1 -R SchoolEngine/architecture --json id -q .id)
  gh api graphql -f query='mutation($p:ID!,$u:String!){addSubIssue(input:{issueId:$p,subIssueUrl:$u}){subIssue{number}}}' \
    -f p="$EPIC" -f u="https://github.com/SchoolEngine/.github/issues/<n>"
  ```

- No epic fits (unplanned fix, new request): stop and ask Céline.
- Technical progress (status, priority, iterations) is followed in the SchoolEngine organisation project, which has no value field.

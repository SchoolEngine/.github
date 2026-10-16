# Dependency updates with Dependabot

SchoolEngine repositories keep their dependencies up to date with Dependabot version updates and Dependabot security updates (ADR-014 in `SchoolEngine/architecture`; Dependabot replaces the Renovate of the founding specification). Dependabot alerts are enabled on the organisation.

## Templates

| Template | For | Ecosystems |
|---|---|---|
| [`common.yml`](templates/dependabot/common.yml) | Repositories without a package manifest (`architecture`, `.github`, `infrastructure`), and every repository until its manifest exists | `github-actions` |
| [`node.yml`](templates/dependabot/node.yml) | pnpm repositories (`contracts`, `backend`, `parent-web`, `admin-web`) | `github-actions`, `npm` (reads `pnpm-lock.yaml`) |
| [`flutter.yml`](templates/dependabot/flutter.yml) | `mobile-app` | `github-actions`, `pub` |
| [`container.yml`](templates/dependabot/container.yml) | Entry to append in a repository that builds an OCI image (`backend`, `infrastructure` if it holds image definitions) | `docker` |

## Using a template

1. **Each repository's CI ticket** copies `common.yml` to `.github/dependabot.yml`, in the same PR as its `ci.yml`.
2. **Each scaffold ticket** switches to `node.yml` or `flutter.yml` in the PR that commits the manifest and its lockfile (`package.json` + `pnpm-lock.yaml`, `pubspec.yaml` + `pubspec.lock`). An ecosystem is never declared before its manifest exists: Dependabot reports an error for it.
3. A repository that builds an image names its image file `Containerfile` (Podman's name, read by Dependabot's `docker` ecosystem like `Dockerfile`) and appends the entry of `container.yml` to its `updates:` list.

Keep the shared settings below when adapting a template; a different `directory` (for example a workspace package) is the only expected change.

## Shared settings

- **Weekly**, Monday 06:00 Europe/Brussels.
- **Cooldown of 7 days**: a newly published version waits a week before Dependabot proposes it, which keeps most compromised releases out. The cooldown applies to version updates only.
- **Grouping**: minor and patch version updates of an ecosystem come in one PR per week; a major update gets its own PR.
- **Security updates are never delayed**: they are raised as soon as an alert exists, outside the schedule and the cooldown, and are not grouped (the groups apply to `version-updates` only). GitHub offers no security updates for the `docker` ecosystem: image vulnerabilities are a deferred control of ADR-014.
- **Commit messages and PR titles** start with `chore(deps):` (or `chore(deps-dev):` for development dependencies), which passes the Conventional Commits check of the `Quality Gate` (see [CI.md](CI.md)).
- **Label** `tech-debt`. The label must exist in the repository, otherwise Dependabot opens the PR without it.

## Reviewing a Dependabot PR

A Dependabot PR goes through the same `Quality Gate` as any other and is merged the same way: squash, with Céline's approval. It is exempt from the `Closes #n` check only, since it has no issue. A red gate on a Dependabot PR is fixed in that PR or in a linked ticket, never bypassed. Since `develop` requires branches to be up to date before merge, a Dependabot PR left behind `develop` is rebased by Dependabot itself: comment `@dependabot rebase` (it also rebases on its own when the PR conflicts). Never use Update branch or push to it: once someone else pushes, Dependabot stops updating that PR.

Tool versions downloaded inside CI steps (gitleaks, osv-scanner, actionlint, oasdiff, the Flutter SDK, Node.js) are invisible to Dependabot and are bumped by hand in the CI templates (see [CI.md](CI.md)).

## Ignored majors

The `node.yml` template ignores two semver-major updates in every `npm` ecosystem. A major of either package is closed with a comment, never merged on its own:

- **`@types/node`** follows the Node.js runtime we pin (Node 24 LTS). A newer major of the types describes APIs that do not exist at runtime. Change the rule when the LTS pin moves.
- **`typescript`** stays on 6.0.x in every repository, because typescript-eslint supports TypeScript < 6.1 only. Lift the rule when typescript-eslint supports TypeScript 7, then bump every repository in one coordinated change.

`update-types` filters version updates only: minor and patch updates of both packages, and every security update, still come.

## Generated API clients

`@usc/api-client` and `usc_api_client` are git-tag dependencies on the private `contracts` repository (ADR-013, SchoolEngine/architecture#6). The templates **ignore** them: they are bumped by the contract change procedure (a PR per consumer after a new contracts tag), not by Dependabot. If ADR-013 shows that Dependabot can propose those tag bumps, remove the `ignore` entry; Dependabot then also needs read access to `contracts` (organisation setting "Grant Dependabot access to private repositories").

## pnpm version

GitHub documents Dependabot support for pnpm v7 to v10. Each pnpm repository pins a supported major in the `packageManager` field of `package.json` (`pnpm@10.34.6` on 2026-10-15) and moves to a newer major only once GitHub lists it.

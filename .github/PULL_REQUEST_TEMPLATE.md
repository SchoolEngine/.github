<!--
Title = the squash commit message, Conventional Commits with the issue number:
feat(auth): add refresh token rotation (#42)
Target size: under ~400 diff lines. Split larger changes.
-->

Closes #

## Context

<!-- Why this change, with the link to the spec section or ADR. -->

## Changes

<!-- What this PR changes, file or module by module. -->

## Review first

<!-- The points a reviewer should look at first: risky logic, security, decisions taken in the PR, open questions. -->

<!--
Gate change only (a CI job removed, a common job or the Quality Gate changed, gitleaks loosened):
use a `ci` title and add a `## Gate change` section with the justification (CI.md, Gate integrity).
-->

## Contract impact

<!-- Keep one line. A breaking change needs the `breaking-change-approved` label, a major bump, a migration note and a plan per consumer. -->

- none
- additive
- breaking

## Definition of Done (spec §38)

- [ ] Acceptance criteria of the issue demonstrated (automated test or capture)
- [ ] Tests written or adapted at every relevant level (§28), coverage threshold respected
- [ ] `Quality Gate` green (format, lint, types, tests, security, contract)
- [ ] No secret, no personal data, no new personal data in logs; synthetic data only
- [ ] Contracts: spec updated, clients regenerated, impacted consumers handled or ticketed (or n/a)
- [ ] Documentation updated in the same PR (README, runbook, ADR; `SoutienScolaireApp/docs` PR linked if structural)
- [ ] Repo map (`.claude/docs/usc-repo-map.md`) updated if a key folder, entry point, pattern or pitfall changed
- [ ] DB migration replayable, tested, expand/contract compliant (or n/a)
- [ ] Verified on staging after merge (or n/a)

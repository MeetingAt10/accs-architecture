# 0002. Host the design system site in the dev stack, deploy it from GitHub Actions through OIDC

- Status: Accepted
- Date: 2026-10-25

## Context

The design system (`MeetingAt10/meetingatten-design-system`) ships a public, search-indexed showcase built with Next.js static export. The other sites are uploaded by `scripts/deploy-dev.sh` from local sibling checkouts. The design system releases by git tag and should publish on its own.

## Decision

- Add `DesignSite`, a fourth `static-site.yaml` nested stack, to `envs/dev/main.yaml`.
- Add `DesignDeployRole` (`templates/github-deploy-role.yaml`): an IAM role trusted through the GitHub OIDC provider, only for `repo:MeetingAt10/meetingatten-design-system:ref:refs/tags/v*`, allowed to list and write that one bucket and invalidate that one distribution.
- The design system's `deploy-site.yml` workflow builds the site on tag push and uploads it with that role.

## Consequences

- No long-lived AWS keys in GitHub; access ends with the tag-scoped trust policy.
- An AWS account holds one GitHub OIDC provider per URL: the template creates it unless `GithubOidcProviderArn` points to an existing one.
- The four `DESIGN_SITE_*` repository variables must be set from the stack outputs after the first deploy; until then the workflow is skipped.
- The shared CloudFront Function now serves extensionless Open Graph image paths as-is (also affects the other sites, harmlessly).

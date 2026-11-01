# 0005. Deploy the accs-dev stack from GitHub Actions on push to main

- Status: Accepted
- Date: 2026-11-02

## Context

Stack changes were applied by hand with `scripts/deploy-dev.sh`, so a merged template could sit undeployed, and the deployed stack could drift from `main`. Backend CI already ships code that expects new infrastructure (for example the DOC006 tables), which breaks when the stack lags behind.

## Decision

- `.github/workflows/deploy-infra.yml` runs on pull requests and on pushes to `main` that touch `cloudformation/**` or the workflow, and on manual dispatch.
- Every run lints the templates with `cfn-lint` (errors fail; warnings such as W3002 for local `TemplateURL` paths do not).
- On `main` only, it also runs `aws cloudformation validate-template`, `cloudformation package`, and `cloudformation deploy --no-fail-on-empty-changeset`: no change set, no deploy. Stack parameters keep their current values; `ApiCodeKey` stays whatever `deploy-dev.sh` last set (backend CI updates Lambda code directly).
- One deploy at a time (`concurrency: accs-dev-infra`, queued, never cancelled mid-update).
- Credentials come from GitHub OIDC, no stored keys. The role `github-accs-infra-deploy` (`templates/github-infra-role.yaml`) trusts only `repo:MeetingAt10@343086680/accs-architecture@1420955976:ref:refs/heads/main`, the repo's immutable subject. It has `PowerUserAccess` plus IAM limited to `accs-dev-*` roles and read/tag on the GitHub OIDC provider, matching the `dev` user.
- The role lives in its own stack, `accs-infra-ci`, deployed by hand. Its name does not match `accs-dev-*`, so the workflow cannot change its own permissions or trust.
- The role ARN is the repository variable `INFRA_DEPLOY_ROLE_ARN`.

## Consequences

- A push to `main` changes AWS within minutes. Review template changes in a pull request first; the PR run shows lint results but does not deploy.
- Anyone who can push to `main` can change any resource the role reaches, including the Lambda's permissions and the DynamoDB tables. Protect `main` (required review) to keep that in check.
- Tables keep `DeletionPolicy: Retain` and deletion protection, so a template that drops a table removes it from the stack but leaves it and its data in the account.
- `deploy-dev.sh` stays for full deploys that also build and upload the sites and API bundle.

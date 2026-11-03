# Architecture

AWS infrastructure provisioned with CloudFormation and configured with AWS Systems Manager (SSM).

- `cloudformation/` — AWS provisioning
  - `templates/` — nested stacks: `static-site.yaml` (private S3 + CloudFront), `api.yaml` (Lambda + HTTP API), `database.yaml` (twelve DynamoDB domain tables), `github-deploy-role.yaml` (GitHub OIDC role that publishes one site)
  - `envs/dev/main.yaml` — dev root stack: accs-landing, meeting@10-website, the seven accs-system app sites (portal + forums, schedule, cases, evaluations, records, admin), accs-system backend and its DynamoDB table, design system site (+ its deploy role)
- `.github/workflows/deploy-infra.yml` — CI: lints templates on every PR and push; on `main` validates and deploys stacks `accs-dev` and then `accs-prod`, each when its change set is not empty (ADR 0005)
- `scripts/deploy-dev.sh` — builds every app, deploys the stack, uploads the sites
  - `scripts/deploy-app-sites.sh` — deploys only the ACCS app sites and API (never landing or meeting)
- `ssm/` — host configuration
  - `documents/` — SSM Command/Automation documents, applied via State Manager associations declared in CloudFormation (`AWS::SSM::Association`), targeting instances by tag
- `iam/` — inline policies of the IAM users (users and access keys are created by hand, see Access)
- `adr/` — architecture decision records (one per decision)
- `diagrams/` — system, deployment, and data-flow diagrams

Configuration values and secrets go in SSM Parameter Store / Secrets Manager, not in the repo.

## How it fits together

### Runtime (dev)

```mermaid
flowchart LR
  user([Browser])

  subgraph aws["AWS account (meetingatten) · ap-southeast-1"]
    subgraph edge["CloudFront (global edge)"]
      cfLanding["accs-landing<br/>distribution"]
      cfMeeting["meeting@10-website<br/>distribution"]
      cfApp["accs-system frontend<br/>distribution"]
      fn["CloudFront Function<br/>/path → /path/index.html"]
    end

    s3Landing[("S3 · landing<br/>private")]
    s3Meeting[("S3 · meeting site<br/>private")]
    s3App[("S3 · frontend<br/>private")]

    apigw["API Gateway<br/>HTTP API"]
    lambda["Lambda · Node 22 arm64<br/>Express app (accs-backend)"]
    logs[("CloudWatch Logs<br/>14-day retention")]
    ddb[("DynamoDB · 12 domain tables<br/>accs-dev-ccs_*, on-demand")]
  end

  user -->|HTTPS| cfLanding & cfMeeting & cfApp
  cfLanding & cfMeeting & cfApp -. viewer-request .-> fn
  cfLanding -->|OAC signed| s3Landing
  cfMeeting -->|OAC signed| s3Meeting
  cfApp -->|OAC signed| s3App
  user -->|HTTPS /api/*| apigw --> lambda --> logs
  lambda -->|item read/write| ddb
```

- Buckets block all public access; only their own CloudFront distribution can read them (Origin Access Control).
- Missing paths: the Next.js sites return `/404.html`, the frontend SPA falls back to `/index.html` for client-side routing.
- Accounts: `api.yaml` creates a private, encrypted, versioned `AuthStoreBucket` (retained on stack delete). The Lambda gets `AUTH_STORE_BUCKET` and may only read/write `auth-store.json` in it (plus `ListBucket`, so a missing object reads as empty). It holds registered accounts and scrypt password hashes; the backend reads it with ETag caching and writes it with a conditional put, so registrations and password changes survive cold starts and are seen by every Lambda instance.
- Database: `database.yaml` creates the twelve DynamoDB domain tables of the DOC006 data dictionary, named `accs-dev-ccs_identity`, `accs-dev-ccs_grievance`, … (on-demand, PITR, deletion protection, retained on stack delete; TTL on `ccs_identity`, `ccs_notification`, `ccs_assistant`). Generic keys `PK`/`SK` with overloaded indexes `GSI1`…`GSI6` (36 in total); tables, indexes, and deviations from DOC006 are in ADR 0004, which supersedes the single-table ADR 0003. The Lambda gets `TABLE_PREFIX` and item-level actions on the business tables and their indexes, but not `Scan`; on `ccs_audit` it may only add and read entries. The root stack outputs `TablePrefix`. The auth store bucket stays until the backend moves accounts into `ccs_identity`.
- The API only accepts browser requests from the seven ACCS app sites' CloudFront URLs: `CORS_ORIGIN` is a comma-separated list the backend parses (`AppSite` plus the six module sites).
- The app is seven CloudFront/S3 sites, all `static-site.yaml` with `Spa=true`, each serving the same frontend `dist/`: `AppSite` (the portal, its distribution and URL unchanged), `ForumsSite`, `ScheduleSite`, `CasesSite`, `EvaluationsSite`, `RecordsSite`, `AdminSite`. Outputs per site: `<Prefix>Url`, `<Prefix>Bucket`, `<Prefix>DistributionId` (prefix `App`, `Forums`, `Schedule`, `Cases`, `Evaluations`, `Records`, `Admin`). The `SiteOrigins` output is a JSON map of site key to URL (`{"portal":...,"forums":...,"admin":...}`) that the frontend build reads as `VITE_SITE_ORIGINS`.
- The design system site (`DesignSite`) is not uploaded by `deploy-dev.sh`: pushing a `v*` tag in `MeetingAt10/meetingatten-design-system` runs its `deploy-site.yml`, which assumes `DesignDeployRole` through GitHub OIDC (no AWS keys in GitHub) and may only sync that bucket and invalidate that distribution. After the first stack deploy, set the repository variables `DESIGN_SITE_ROLE_ARN`, `DESIGN_SITE_BUCKET`, `DESIGN_SITE_DISTRIBUTION_ID` and `DESIGN_SITE_URL` from the `Design*` outputs. If the account already has a GitHub OIDC provider, pass its ARN as `GithubOidcProviderArn`. The repo issues immutable OIDC subjects (`repo:MeetingAt10@343086680/meetingatten-design-system@1431974802:...`), so `DesignSystemRepository` uses that form; a renamed or re-created repo cannot assume the role.
- The CloudFront Function leaves `.../opengraph-image` and `.../twitter-image` paths (optionally with a `-<hash>` suffix) alone: Next.js writes those images without an extension.

### CloudFormation stacks

```mermaid
flowchart TB
  root["accs-dev<br/>envs/dev/main.yaml"]
  root --> landing["LandingSite<br/>static-site.yaml"]
  root --> meeting["MeetingSite<br/>static-site.yaml"]
  root --> app["AppSite<br/>static-site.yaml · Spa=true"]
  root --> modules["ForumsSite, ScheduleSite, CasesSite,<br/>EvaluationsSite, RecordsSite, AdminSite<br/>static-site.yaml · Spa=true"]
  root --> design["DesignSite<br/>static-site.yaml"]
  root --> role["DesignDeployRole<br/>github-deploy-role.yaml"]
  design -. bucket + distribution .-> role
  root --> db["Database<br/>database.yaml"]
  root --> api["Api<br/>api.yaml"]
  db -. TableName + TableArn .-> api
  app & modules -. Url list to CorsOrigin .-> api

  subgraph site["static-site.yaml creates"]
    direction LR
    b[S3 bucket] --- oac[Origin Access Control] --- cff[CloudFront Function] --- dist[Distribution] --- pol[Bucket policy]
  end
  subgraph dbt["database.yaml creates"]
    direction LR
    t[(12 DynamoDB tables<br/>PK/SK + GSI1..GSI6)]
  end
  subgraph apit["api.yaml creates"]
    direction LR
    role[IAM role] --- f[Lambda function] --- ab[(Auth store S3 bucket)] --- lg[Log group] --- http[HTTP API] --- perm[Invoke permission]
  end
```

### Deploy flow (`scripts/deploy-dev.sh`)

```mermaid
sequenceDiagram
  autonumber
  participant Dev as deploy-dev.sh
  participant Art as S3 artifacts bucket
  participant CFN as CloudFormation
  participant Site as S3 site buckets
  participant CF as CloudFront

  Dev->>Art: create bucket (first run only)
  Dev->>Dev: backend: npm ci + build:lambda (esbuild)
  Dev->>Art: upload api/SHA.zip
  Dev->>Art: cloudformation package (nested templates)
  Dev->>CFN: deploy stack accs-dev (ApiCodeKey = new zip)
  CFN-->>Dev: outputs (bucket names, distribution IDs, URLs)
  loop accs-landing, meeting@10-website, frontend
    Dev->>Dev: npm ci + npm run build
    Dev->>Site: aws s3 sync --delete
    Dev->>CF: invalidate /*
  end
  Dev-->>Dev: print LandingUrl, MeetingUrl, AppUrl, ApiUrl
```

### Host configuration (planned, SSM)

No EC2 hosts exist yet. When some are added, they are configured like this:

```mermaid
flowchart LR
  docs["ssm/documents/*<br/>(Command / Automation)"] --> assoc["State Manager association<br/>AWS::SSM::Association"]
  params[("Parameter Store /<br/>Secrets Manager")] -.values.-> assoc
  assoc -->|targets by tag| ec2["EC2 instances<br/>SSM Agent + AmazonSSMManagedInstanceCore"]
```

## Deploy (dev)

Target: AWS account behind the `meetingatten` CLI profile, `ap-southeast-1`. Needs sibling checkouts of `backend/`, `frontend/`, `../accs-landing`, `../meeting@10-website`.

```sh
pcore scripts/deploy-dev.sh
```

The script creates the `accs-dev-artifacts-<account>` bucket on first run, uploads the API bundle and nested templates there, deploys stack `accs-dev`, then syncs each site and invalidates CloudFront. Override with `AWS_PROFILE`, `STACK`, or `*_DIR` env vars.

To redeploy only the ACCS app and API, leaving landing and meeting untouched:

```sh
pcore scripts/deploy-app-sites.sh
SKIP_STACK=1 pcore scripts/deploy-app-sites.sh   # sites only: skip backend build and stack deploy
```

It builds the frontend once with `VITE_API_URL` and `VITE_SITE_ORIGINS` from the stack outputs, then syncs the build to all seven buckets and invalidates each distribution. Set `SESSION_SECRET` in the environment to inline it into the Lambda bundle, as backend CI does; without it the API signs sessions with a random per-instance key.

### Environments and hostnames (`access-ccs.com`)

`access-ccs.com` is registered with Route 53 in this account (hosted zone `Z09799202NPP9TLA01MFH`). The same root template, `envs/dev/main.yaml`, runs as two stacks:

| Stack | Branch | `Env` | `HostSuffix` | Tables |
|---|---|---|---|---|
| `accs-prod` | `main` (design system: `v*` tags) | `prod` | empty | `accs-prod-ccs_*` |
| `accs-dev` | `dev` (design system: `master`) | `dev` | `-dev` | `accs-dev-ccs_*` |

| Site | Prod hostname | Dev hostname |
|---|---|---|
| Landing | `access-ccs.com`, `www.access-ccs.com` | none (prod only) |
| Portal (Home) | `portal.access-ccs.com` | `portal-dev.access-ccs.com` |
| Forums | `forums.access-ccs.com` | `forums-dev.access-ccs.com` |
| Schedule | `schedule.access-ccs.com` | `schedule-dev.access-ccs.com` |
| Cases | `cases.access-ccs.com` | `cases-dev.access-ccs.com` |
| Evaluations | `evaluations.access-ccs.com` | `evaluations-dev.access-ccs.com` |
| Records | `records.access-ccs.com` | `records-dev.access-ccs.com` |
| Admin | `admin.access-ccs.com` | `admin-dev.access-ccs.com` |
| Design system | `design.access-ccs.com` | `design-dev.access-ccs.com` |
| Meeting At 10 | `team.access-ccs.com` | `team-dev.access-ccs.com` |

Each stack has its own API, Lambda, tables and auth store, so dev data and accounts never reach prod. The seeded accounts' shared password is the `NoEcho` stack parameter `SeedPassword` (Lambda `SEED_PASSWORD`), different per stack. Set it by hand with `aws cloudformation deploy ... --parameter-overrides SeedPassword='<value>'`; CI deploys keep the current value. When it is empty, the API disables seeded sign-in. The stack name `accs-dev` predates the split; it is the dev environment.

App CI picks the stack from the branch: `main` deploys to `accs-prod`, `dev` to `accs-dev` (frontend, backend and meeting@10; the landing deploys from `main` to `accs-prod` only). Backend CI reads the Lambda name from the stack output `ApiFunctionName`.

CloudFront only accepts certificates from us-east-1, so the certificate for `access-ccs.com` and `*.access-ccs.com` lives in a separate stack, `accs-dev-certificate`, in us-east-1. Both environments share it. It validates itself through a DNS record in the hosted zone. Deploy it by hand, and pass its ARN to `envs/dev/main.yaml` as the `CertificateArn` default:

```sh
aws cloudformation deploy --region us-east-1 --template-file templates/certificate.yaml \
  --stack-name accs-dev-certificate --no-fail-on-empty-changeset
```

`static-site.yaml` adds the aliases, the certificate, and Route 53 A/AAAA alias records when `DomainName` is set. Its `Url` output is then the custom hostname, so `SiteOrigins` and the API's CORS list follow automatically. The CloudFront default hostnames (`DefaultUrl`) still work, and they stay in the CORS list too.

A hostname can sit on only one distribution, so moving a hostname between stacks means removing it from one stack before adding it to the other. Sites are created in two `DependsOn` chains because CloudFront rejects ten function creations at once ("Rate exceeded").

### CI deploy (`deploy-infra.yml`)

Pushing to `main` with changes under `cloudformation/` deploys the stack: `cfn-lint`, then `validate-template`, `cloudformation package`, and `cloudformation deploy --no-fail-on-empty-changeset` (nothing deploys if nothing changed). Pull requests only lint. The job assumes `github-accs-infra-deploy` through GitHub OIDC (ARN in the repo variable `INFRA_DEPLOY_ROLE_ARN`); that role is in its own stack, `accs-infra-ci`, which you deploy by hand:

```sh
aws cloudformation deploy --template-file cloudformation/templates/github-infra-role.yaml \
  --stack-name accs-infra-ci --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides OidcProviderArn=arn:aws:iam::128908383744:oidc-provider/token.actions.githubusercontent.com
```

Stack parameters keep their current values, so CI never changes `ApiCodeKey`. Run `deploy-dev.sh` when the sites or the API bundle need rebuilding too.

## Access (IAM users)

Two IAM users with long-lived access keys, created by hand (not in CloudFormation, so no secret ever lands in a template or stack output). Keys are handed over as CSV files outside any repo and are never committed.

| User | For | Permissions |
|---|---|---|
| `dev` | Local work: `deploy-dev.sh`, stack changes | `PowerUserAccess` + `iam/dev-user-policy.json` (manage `accs-*` roles and the GitHub OIDC provider, which the stacks create) |
| `deploy` | App CI/CD | managed policy `accs-deploy-sites-and-api` (`iam/deploy-user-policy.json`) only: read `accs-dev` and `accs-prod` outputs, sync the site buckets, invalidate the listed distributions, update the API Lambda code. No access to the artifacts bucket, so CI cannot alter the templates CloudFormation deploys |

- `dev` can create `accs-*` roles with any policy, so treat its key like an admin key.
- The deploy policy lists distribution IDs, not a wildcard (a wildcard would also allow invalidating landing and meeting). The bucket patterns `accs-dev-*site-*-bucket-*` and `accs-prod-*site-*-bucket-*` cover every site bucket, but `InvalidateCdn` lists the distribution IDs of both stacks: update it whenever a site stack is created or recreated. Until then CI invalidation of the new sites fails with access denied. The policy is too large for an inline user policy (2048-byte limit), so it is the managed policy `accs-deploy-sites-and-api`, attached to `deploy`. Publish a new version with `aws iam create-policy-version --policy-arn arn:aws:iam::128908383744:policy/accs-deploy-sites-and-api --policy-document file://iam/deploy-user-policy.json --set-as-default` (IAM keeps at most five versions; delete an old one first if needed).
- The design system site does not use `deploy`: it publishes through `DesignDeployRole` (OIDC, ADR 0002).
- Rotate a key: `aws iam create-access-key --user-name <user>`, switch consumers over, then `aws iam delete-access-key --user-name <user> --access-key-id <old>`.

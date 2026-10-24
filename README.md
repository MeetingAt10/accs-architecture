# Architecture

AWS infrastructure provisioned with CloudFormation and configured with AWS Systems Manager (SSM). System concept not defined yet.

- `cloudformation/` — AWS provisioning
  - `templates/` — nested stacks: `static-site.yaml` (private S3 + CloudFront), `api.yaml` (Lambda + HTTP API)
  - `envs/dev/main.yaml` — dev root stack: accs-landing, meeting@10-website, accs-system frontend, accs-system backend
- `scripts/deploy-dev.sh` — builds every app, deploys the stack, uploads the sites
- `ssm/` — host configuration
  - `documents/` — SSM Command/Automation documents, applied via State Manager associations declared in CloudFormation (`AWS::SSM::Association`), targeting instances by tag
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
  end

  user -->|HTTPS| cfLanding & cfMeeting & cfApp
  cfLanding & cfMeeting & cfApp -. viewer-request .-> fn
  cfLanding -->|OAC signed| s3Landing
  cfMeeting -->|OAC signed| s3Meeting
  cfApp -->|OAC signed| s3App
  user -->|HTTPS /api/*| apigw --> lambda --> logs
```

- Buckets block all public access; only their own CloudFront distribution can read them (Origin Access Control).
- Missing paths: the Next.js sites return `/404.html`, the frontend SPA falls back to `/index.html` for client-side routing.
- The API only accepts browser requests from the frontend's CloudFront URL (`CORS_ORIGIN`).

### CloudFormation stacks

```mermaid
flowchart TB
  root["accs-dev<br/>envs/dev/main.yaml"]
  root --> landing["LandingSite<br/>static-site.yaml"]
  root --> meeting["MeetingSite<br/>static-site.yaml"]
  root --> app["AppSite<br/>static-site.yaml · Spa=true"]
  root --> api["Api<br/>api.yaml"]
  app -. Url to CorsOrigin .-> api

  subgraph site["static-site.yaml creates"]
    direction LR
    b[S3 bucket] --- oac[Origin Access Control] --- cff[CloudFront Function] --- dist[Distribution] --- pol[Bucket policy]
  end
  subgraph apit["api.yaml creates"]
    direction LR
    role[IAM role] --- f[Lambda function] --- lg[Log group] --- http[HTTP API] --- perm[Invoke permission]
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

Sites get default `*.cloudfront.net` URLs; no custom domain yet.

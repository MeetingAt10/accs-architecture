# Architecture

AWS infrastructure provisioned with CloudFormation and configured with AWS Systems Manager (SSM). System concept not defined yet.

- `cloudformation/` — AWS provisioning
  - `templates/` — reusable nested-stack templates
  - `envs/dev/` — dev environment root stack (`main.yaml`) and `parameters.json`
- `ssm/` — host configuration
  - `documents/` — SSM Command/Automation documents, applied via State Manager associations declared in CloudFormation (`AWS::SSM::Association`), targeting instances by tag
- `adr/` — architecture decision records (one per decision)
- `diagrams/` — system, deployment, and data-flow diagrams

Configuration values and secrets go in SSM Parameter Store / Secrets Manager, not in the repo.

## Deploy (dev)

```sh
cd cloudformation
aws cloudformation package --template-file envs/dev/main.yaml \
  --s3-bucket <artifact-bucket> --output-template-file packaged-dev.yaml
aws cloudformation deploy --template-file packaged-dev.yaml \
  --stack-name accs-dev --region ap-southeast-1 \
  --parameter-overrides file://envs/dev/parameters.json \
  --tags Project=accs Environment=dev ManagedBy=cloudformation
```

`package` is only needed once `main.yaml` references nested templates or local files.

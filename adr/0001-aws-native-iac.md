# 0001. Use AWS-native tooling for provisioning and configuration

- Status: Accepted
- Date: 2026-10-24

## Context

The scaffold started with Terraform for provisioning and Ansible for host configuration. The project targets AWS only.

## Decision

Use AWS-native services instead:

| Replaced | With |
|---|---|
| Terraform root module / modules | CloudFormation root stack / nested-stack templates |
| `*.tfvars`, provider `default_tags` | `parameters.json`, stack-level `--tags` |
| Terraform state | Managed by CloudFormation |
| Ansible playbooks / roles | SSM documents (Run Command, Automation) |
| Ansible inventory | SSM targets by EC2 tag / resource group |
| `site.yml` runs | State Manager associations (`AWS::SSM::Association`) |
| `group_vars` / vault | SSM Parameter Store / Secrets Manager |

## Consequences

- No third-party CLI or state backend to manage; everything runs through the AWS CLI/console.
- Instances need the SSM Agent and an instance profile with `AmazonSSMManagedInstanceCore`; no SSH access required.
- Locked to AWS; moving clouds later means rewriting IaC.

# Architecture

AWS infrastructure provisioned with Terraform and configured with Ansible. System concept not defined yet.

- `terraform/` — AWS provisioning
  - `modules/` — reusable modules
  - `envs/dev/` — dev environment root module
- `ansible/` — host configuration
  - `inventory/`, `playbooks/`, `roles/`, `group_vars/`
- `adr/` — architecture decision records (one per decision)
- `diagrams/` — system, deployment, and data-flow diagrams

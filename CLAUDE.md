# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

`cowork-infra` holds infrastructure-as-code, CI/CD configuration, and the architecture design docs for the entire cowork project. It does not contain product business logic.

## Architecture

```
iac/    ← Terraform / CDK (ECS clusters, ALB, DynamoDB tables, S3 buckets, IAM)
ci/     ← CI/CD templates (Docker build, ECS deploy, schema codegen)
docs/   ← Architecture design docs, ADRs, runbooks, threat models
```

## Infrastructure Conventions

- **Compute:** AWS ECS Fargate. One ECS service per backend service (always-running). On-demand Fargate tasks for cloud sandbox containers (one task per sandbox session, launched by Session Service via `RunTask`).
- **Networking:** ALB with path-based routing (`/sessions/*`, `/workspaces/*`, `/approvals/*`, etc.). Inter-service calls via ALB or ECS Service Connect.
- **Environments:** `dev`, `staging`, `prod` — each a separate ECS cluster with its own ALB, DynamoDB tables, and S3 buckets.
- **Environment variable:** Passed as container env var, prefixes all resource names.

## DynamoDB Conventions

- Table names: `{env}-sessions`, `{env}-workspaces`, `{env}-artifacts`, `{env}-approvals`, `{env}-audit-events`, `{env}-policies`
- All items include `createdAt` (ISO 8601) and `updatedAt`
- TTL attribute always named `ttl` (Unix epoch seconds)
- GSIs defined per-service in their design docs

## S3 Conventions

- Bucket: `{env}-workspace-artifacts`
- Object key: `{workspaceId}/{sessionId}/{artifactType}/{artifactId}`

## Design Docs (in `docs/`)

| Doc | Scope |
|-----|-------|
| `architecture.md` | Master architecture — start here |
| `domain-model.md` | Entity hierarchy, session types, message storage |
| `components/local-agent-host.md` | Agent loop, policy enforcer, state store |
| `components/local-tool-runtime.md` | Tools, platform adapters, MCP client |
| `components/desktop-app.md` | UI views, IPC client, updater |
| `services/session-service.md` | Session CRUD, compatibility check |
| `services/policy-service.md` | Policy bundle, capability model |
| `services/workspace-service.md` | Artifact storage, S3 integration |
| `services/approval-service.md` | Approval flow, risk levels |
| `services/audit-service.md` | Audit events (Phase 3) |
| `services/telemetry-service.md` | Traces/metrics (Phase 3) |
| `services/backend-tool-service.md` | Remote tools (Phase 3) |

## Local Testing Infrastructure

```bash
# DynamoDB Local — for service-level tests
docker run -p 8000:8000 amazon/dynamodb-local

# LocalStack — for integration tests (S3 + DynamoDB)
docker run -p 4566:4566 localstack/localstack
```

Services connect via `AWS_ENDPOINT_URL` env var. Same SDK code runs in all environments.

---

## Engineering Standards

### Project Structure

```
cowork-infra/
  CLAUDE.md
  README.md
  Makefile
  docs/                       # Architecture design docs (source of truth)
    architecture.md
    domain-model.md
    components/
    services/
    adr/                      # Architecture Decision Records
  iac/
    modules/                  # Reusable Terraform modules
      ecs-service/            # Generic Fargate service module
      dynamodb-table/         # Generic DynamoDB table module
      s3-bucket/              # Generic S3 bucket module
      alb/                    # ALB + listener rules module
      iam/                    # Service-specific IAM roles
      sandbox/                # Sandbox task definition, security group, IAM roles
    environments/
      dev/
        main.tf
        variables.tf
        outputs.tf
        terraform.tfvars
      staging/
      prod/
    backend.tf                # S3 backend configuration for state
  ci/                         # CI/CD templates
    docker-build.yml          # Reusable Docker build workflow
    ecs-deploy.yml            # ECS deployment workflow
    schema-codegen.yml        # Platform contract codegen
```

### Terraform Conventions

- **Version**: Terraform >= 1.10, AWS provider >= 5.80
- **State**: S3 backend with DynamoDB state locking. One state file per environment.
- **Modules**: Reusable in `iac/modules/`. Service-specific composition in `iac/environments/{env}/`.
- **Naming**: All resources prefixed `cowork-{env}-`. Tags: `Project=cowork`, `Environment={env}`, `ManagedBy=terraform`.
- **Variables**: No defaults for environment-specific values (force explicit configuration).
- **Outputs**: Every module exports ARNs, names, and endpoints.
- **Formatting**: `terraform fmt` enforced in CI.

### Environment Management

- Three environments: `dev`, `staging`, `prod`
- Environment parity: same Terraform modules, different variable values (instance counts, capacity, alarms)
- Promotion: `dev` → `staging` → `prod`. Never skip staging.
- Environment-specific secrets in AWS Secrets Manager, referenced by ARN in Terraform.

### Makefile Targets

```
make help              # Show all targets
make fmt               # terraform fmt -recursive
make validate          # terraform validate (all environments)
make plan-dev          # terraform plan for dev
make plan-staging      # terraform plan for staging
make plan-prod         # terraform plan for prod
make apply-dev         # terraform apply for dev
make apply-staging     # terraform apply for staging
make apply-prod        # terraform apply for prod (requires approval)
make lint-docs         # Lint markdown docs
make clean             # Remove .terraform directories and plan files
```

### Design Docs Maintenance

Design docs in `docs/` are the **source of truth** for all architecture decisions. When any implementation repo diverges from a design doc, the design doc must be updated in the same PR or immediately after. This keeps all repos aligned.

ADRs (Architecture Decision Records) in `docs/adr/` for significant decisions that affect multiple repos.

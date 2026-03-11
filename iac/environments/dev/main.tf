###############################################################################
# Dev Environment — Cowork Backend Services
#
# Composes reusable modules for the dev environment.
# Shared resources (VPC, ECS cluster, ALB) are defined here.
# Service-specific resources use modules.
###############################################################################

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80"
    }
  }

  # Uncomment when S3 backend is provisioned:
  # backend "s3" {
  #   bucket         = "cowork-terraform-state"
  #   key            = "dev/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "cowork-terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "cowork"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

locals {
  env    = var.environment
  prefix = "cowork-${local.env}"
}

# =========================================================================== #
# Shared Infrastructure — VPC, ECS Cluster, ALB
# =========================================================================== #

# --------------------------------------------------------------------------- #
# VPC
# --------------------------------------------------------------------------- #

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.prefix}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.prefix}-igw" }
}

resource "aws_subnet" "public" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone = var.availability_zones[count.index]

  tags = { Name = "${local.prefix}-public-${var.availability_zones[count.index]}" }
}

resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + length(var.availability_zones))
  availability_zone = var.availability_zones[count.index]

  tags = { Name = "${local.prefix}-private-${var.availability_zones[count.index]}" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.prefix}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = { Name = "${local.prefix}-nat" }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.prefix}-public-rt" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.prefix}-private-rt" }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# --------------------------------------------------------------------------- #
# Security Groups
# --------------------------------------------------------------------------- #

resource "aws_security_group" "alb" {
  name_prefix = "${local.prefix}-alb-"
  description = "ALB security group — allows inbound HTTP/HTTPS"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.prefix}-alb-sg" }
}

resource "aws_security_group" "ecs_tasks" {
  name_prefix = "${local.prefix}-ecs-tasks-"
  description = "ECS tasks security group — allows traffic from ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.prefix}-ecs-tasks-sg" }
}

# --------------------------------------------------------------------------- #
# ECS Cluster
# --------------------------------------------------------------------------- #

resource "aws_ecs_cluster" "main" {
  name = "${local.prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "${local.prefix}-cluster" }
}

# --------------------------------------------------------------------------- #
# ALB
# --------------------------------------------------------------------------- #

resource "aws_lb" "main" {
  name               = "${local.prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = { Name = "${local.prefix}-alb" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"error\":\"not_found\"}"
      status_code  = "404"
    }
  }
}

# =========================================================================== #
# Approval Service (Phase 2)
# =========================================================================== #

# --------------------------------------------------------------------------- #
# DynamoDB Table: {env}-approvals
# --------------------------------------------------------------------------- #

module "approvals_table" {
  source = "../../modules/dynamodb-table"

  table_name = "${local.env}-approvals"
  hash_key   = "approvalId"

  attributes = [
    { name = "approvalId", type = "S" },
    { name = "sessionId", type = "S" },
    { name = "clientTimestamp", type = "S" },
  ]

  global_secondary_indexes = [
    {
      name     = "sessionId-index"
      hash_key = "sessionId"
      range_key = "clientTimestamp"
    },
  ]

  ttl_enabled            = true
  ttl_attribute          = "ttl"
  point_in_time_recovery = true
}

# --------------------------------------------------------------------------- #
# ECS Service: approval-service
# --------------------------------------------------------------------------- #

module "approval_service" {
  source = "../../modules/ecs-service"

  service_name    = "${local.prefix}-approval-service"
  container_image = var.approval_service_image
  container_port  = 8000
  cpu             = var.approval_service_cpu
  memory          = var.approval_service_memory
  desired_count   = var.approval_service_desired_count

  environment_variables = {
    ENV                    = local.env
    LOG_LEVEL              = var.log_level
    AWS_REGION             = var.aws_region
    DYNAMODB_TABLE_PREFIX  = "${local.env}-"
  }

  task_policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:Query",
      ]
      Resource = [
        module.approvals_table.table_arn,
        "${module.approvals_table.table_arn}/index/*",
      ]
    },
  ]

  # Networking
  vpc_id             = aws_vpc.main.id
  private_subnet_ids = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.ecs_tasks.id]

  # ALB
  ecs_cluster_id         = aws_ecs_cluster.main.id
  alb_listener_arn       = aws_lb_listener.http.arn
  listener_rule_priority = 400
  path_patterns          = ["/approvals", "/approvals/*"]

  # Observability
  aws_region         = var.aws_region
  log_retention_days = var.log_retention_days
}

# =========================================================================== #
# Session Service (Phase 1)
# =========================================================================== #

module "sessions_table" {
  source = "../../modules/dynamodb-table"

  table_name = "${local.env}-sessions"
  hash_key   = "sessionId"

  attributes = [
    { name = "sessionId", type = "S" },
    { name = "tenantId", type = "S" },
    { name = "createdAt", type = "S" },
  ]

  global_secondary_indexes = [
    {
      name      = "tenantId-userId-index"
      hash_key  = "tenantId"
      range_key = "createdAt"
    },
  ]
}

module "tasks_table" {
  source = "../../modules/dynamodb-table"

  table_name = "${local.env}-tasks"
  hash_key   = "taskId"

  attributes = [
    { name = "taskId", type = "S" },
    { name = "sessionId", type = "S" },
    { name = "createdAt", type = "S" },
  ]

  global_secondary_indexes = [
    {
      name      = "sessionId-index"
      hash_key  = "sessionId"
      range_key = "createdAt"
    },
  ]
}

module "session_service" {
  source = "../../modules/ecs-service"

  service_name    = "${local.prefix}-session-service"
  container_image = var.session_service_image
  container_port  = 8000
  cpu             = 256
  memory          = 512
  desired_count   = 2

  environment_variables = {
    ENV                    = local.env
    LOG_LEVEL              = var.log_level
    AWS_REGION             = var.aws_region
    DYNAMODB_TABLE_PREFIX  = "${local.env}-"
    POLICY_SERVICE_URL     = "http://${aws_lb.main.dns_name}"
    WORKSPACE_SERVICE_URL  = "http://${aws_lb.main.dns_name}"
    # Sandbox ECS configuration
    SANDBOX_LAUNCHER_TYPE  = "ecs"
    ECS_CLUSTER            = aws_ecs_cluster.main.name
    ECS_TASK_DEFINITION    = module.sandbox.task_definition_family
    ECS_SUBNETS            = jsonencode(aws_subnet.private[*].id)
    ECS_SECURITY_GROUPS    = jsonencode([module.sandbox.security_group_id])
  }

  task_policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:UpdateItem",
        "dynamodb:Query",
      ]
      Resource = [
        module.sessions_table.table_arn,
        "${module.sessions_table.table_arn}/index/*",
        module.tasks_table.table_arn,
        "${module.tasks_table.table_arn}/index/*",
      ]
    },
    # ECS RunTask/StopTask for sandbox provisioning and termination
    {
      Effect = "Allow"
      Action = [
        "ecs:RunTask",
        "ecs:StopTask",
        "ecs:DescribeTasks",
      ]
      Resource = [
        module.sandbox.task_definition_arn,
        # RunTask returns task ARNs scoped to the cluster
        "arn:aws:ecs:${var.aws_region}:*:task/${aws_ecs_cluster.main.name}/*",
      ]
    },
    # IAM PassRole — required for RunTask to assign execution/task roles
    {
      Effect = "Allow"
      Action = ["iam:PassRole"]
      Resource = [
        module.sandbox.execution_role_arn,
        module.sandbox.task_role_arn,
      ]
    },
  ]

  vpc_id             = aws_vpc.main.id
  private_subnet_ids = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.ecs_tasks.id]

  ecs_cluster_id         = aws_ecs_cluster.main.id
  alb_listener_arn       = aws_lb_listener.http.arn
  listener_rule_priority = 100
  path_patterns          = ["/sessions", "/sessions/*", "/tasks", "/tasks/*"]

  aws_region         = var.aws_region
  log_retention_days = var.log_retention_days
}

# =========================================================================== #
# Policy Service (Phase 1)
# =========================================================================== #

module "policy_service" {
  source = "../../modules/ecs-service"

  service_name    = "${local.prefix}-policy-service"
  container_image = var.policy_service_image
  container_port  = 8000
  cpu             = 256
  memory          = 512
  desired_count   = 2

  environment_variables = {
    ENV       = local.env
    LOG_LEVEL = var.log_level
    AWS_REGION = var.aws_region
  }

  # Phase 1: static config, no DynamoDB
  task_policy_statements = []

  vpc_id             = aws_vpc.main.id
  private_subnet_ids = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.ecs_tasks.id]

  ecs_cluster_id         = aws_ecs_cluster.main.id
  alb_listener_arn       = aws_lb_listener.http.arn
  listener_rule_priority = 200
  path_patterns          = ["/policies", "/policies/*"]

  aws_region         = var.aws_region
  log_retention_days = var.log_retention_days
}

# =========================================================================== #
# Workspace Service (Phase 1)
# =========================================================================== #

module "workspaces_table" {
  source = "../../modules/dynamodb-table"

  table_name = "${local.env}-workspaces"
  hash_key   = "workspaceId"

  attributes = [
    { name = "workspaceId", type = "S" },
    { name = "tenantId", type = "S" },
    { name = "userId", type = "S" },
    { name = "localPathKey", type = "S" },
  ]

  global_secondary_indexes = [
    {
      name      = "tenantId-userId-index"
      hash_key  = "tenantId"
      range_key = "userId"
    },
    {
      name     = "localpath-lookup-index"
      hash_key = "localPathKey"
    },
  ]
}

module "artifacts_table" {
  source = "../../modules/dynamodb-table"

  table_name = "${local.env}-artifacts"
  hash_key   = "workspaceId"
  range_key  = "artifactId"

  attributes = [
    { name = "workspaceId", type = "S" },
    { name = "artifactId", type = "S" },
    { name = "sessionId", type = "S" },
    { name = "artifactTypeCreatedAt", type = "S" },
  ]

  global_secondary_indexes = [
    {
      name      = "sessionId-type-index"
      hash_key  = "sessionId"
      range_key = "artifactTypeCreatedAt"
    },
  ]
}

resource "aws_s3_bucket" "artifacts" {
  bucket = "${local.prefix}-workspace-artifacts"
  tags   = { Name = "${local.prefix}-workspace-artifacts" }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

module "workspace_service" {
  source = "../../modules/ecs-service"

  service_name    = "${local.prefix}-workspace-service"
  container_image = var.workspace_service_image
  container_port  = 8000
  cpu             = 256
  memory          = 512
  desired_count   = 2

  environment_variables = {
    ENV                    = local.env
    LOG_LEVEL              = var.log_level
    AWS_REGION             = var.aws_region
    DYNAMODB_TABLE_PREFIX  = "${local.env}-"
    S3_BUCKET              = aws_s3_bucket.artifacts.id
    SESSION_SERVICE_URL    = "http://${aws_lb.main.dns_name}"
  }

  task_policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:UpdateItem",
        "dynamodb:Query",
      ]
      Resource = [
        module.workspaces_table.table_arn,
        "${module.workspaces_table.table_arn}/index/*",
        module.artifacts_table.table_arn,
        "${module.artifacts_table.table_arn}/index/*",
      ]
    },
    {
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket",
      ]
      Resource = [
        aws_s3_bucket.artifacts.arn,
        "${aws_s3_bucket.artifacts.arn}/*",
      ]
    },
  ]

  vpc_id             = aws_vpc.main.id
  private_subnet_ids = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.ecs_tasks.id]

  ecs_cluster_id         = aws_ecs_cluster.main.id
  alb_listener_arn       = aws_lb_listener.http.arn
  listener_rule_priority = 300
  path_patterns          = ["/workspaces", "/workspaces/*", "/artifacts", "/artifacts/*"]

  aws_region         = var.aws_region
  log_retention_days = var.log_retention_days
}

# =========================================================================== #
# Sandbox — Agent Runtime ECS Tasks (on-demand, per-session)
# =========================================================================== #

module "sandbox" {
  source = "../../modules/sandbox"

  name_prefix     = local.prefix
  environment     = local.env
  container_image = var.sandbox_image
  cpu             = var.sandbox_cpu
  memory          = var.sandbox_memory

  environment_variables = {
    ENV                   = local.env
    LOG_LEVEL             = var.log_level
    SESSION_SERVICE_URL   = "http://${aws_lb.main.dns_name}"
    WORKSPACE_SERVICE_URL = "http://${aws_lb.main.dns_name}"
    LLM_GATEWAY_ENDPOINT  = var.llm_gateway_endpoint
  }

  # Secrets from AWS Secrets Manager
  secrets = {
    LLM_GATEWAY_AUTH_TOKEN = var.llm_gateway_auth_token_arn
  }

  # Networking — sandbox ingress only from Session Service SG
  vpc_id                = aws_vpc.main.id
  session_service_sg_id = aws_security_group.ecs_tasks.id

  # Storage
  artifacts_bucket_arn = aws_s3_bucket.artifacts.arn

  # Observability
  aws_region         = var.aws_region
  log_retention_days = var.log_retention_days
}

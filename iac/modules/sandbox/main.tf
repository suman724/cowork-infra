###############################################################################
# Sandbox ECS Task Module
#
# Creates on-demand Fargate task resources for agent-runtime sandboxes.
# Unlike ecs-service, there is NO ECS service or ALB — containers are
# launched per-session via RunTask and accessed directly by Session Service.
#
# Resources:
# - ECS task definition (Fargate, awsvpc networking)
# - Security group (ingress only from Session Service SG on port 8080)
# - IAM execution role (ECR pull, CloudWatch Logs)
# - IAM task role (scoped S3, CloudWatch Logs, Session Service registration)
# - CloudWatch log group
###############################################################################

# --------------------------------------------------------------------------- #
# CloudWatch Log Group
# --------------------------------------------------------------------------- #

resource "aws_cloudwatch_log_group" "sandbox" {
  name              = "/cowork/${var.environment}/sandbox"
  retention_in_days = var.log_retention_days
}

# --------------------------------------------------------------------------- #
# Security Group — sandbox containers
# --------------------------------------------------------------------------- #

resource "aws_security_group" "sandbox" {
  name_prefix = "${var.name_prefix}-sandbox-"
  description = "Sandbox containers — ingress from Session Service only"
  vpc_id      = var.vpc_id

  # Agent-runtime HTTP transport listens on port 8080
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [var.session_service_sg_id]
    description     = "Session Service proxy to sandbox"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound (LLM Gateway, Session Service registration, package installs)"
  }
}

# --------------------------------------------------------------------------- #
# IAM — Execution Role (pulls images, writes logs)
# --------------------------------------------------------------------------- #

resource "aws_iam_role" "execution" {
  name = "${var.name_prefix}-sandbox-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow execution role to read secrets from Secrets Manager (for ECS secret injection)
resource "aws_iam_role_policy" "execution_secrets" {
  count = length(var.secrets) > 0 ? 1 : 0

  name = "${var.name_prefix}-sandbox-execution-secrets"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = values(var.secrets)
    }]
  })
}

# --------------------------------------------------------------------------- #
# IAM — Task Role (what the sandbox container can do at runtime)
# --------------------------------------------------------------------------- #

resource "aws_iam_role" "task" {
  name = "${var.name_prefix}-sandbox-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "task" {
  name = "${var.name_prefix}-sandbox-task-policy"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # S3: read/write workspace artifacts scoped to workspaceId prefix
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = "${var.artifacts_bucket_arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
        ]
        Resource = var.artifacts_bucket_arn
      },
      # CloudWatch Logs: write to sandbox log group only
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.sandbox.arn}:*"
      },
    ]
  })
}

# --------------------------------------------------------------------------- #
# ECS Task Definition
# --------------------------------------------------------------------------- #

resource "aws_ecs_task_definition" "sandbox" {
  family                   = "${var.name_prefix}-sandbox"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "agent-runtime"
    image     = var.container_image
    essential = true

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    # Static environment variables — session-specific vars (SESSION_ID,
    # REGISTRATION_TOKEN, etc.) are passed as overrides in RunTask
    environment = [for k, v in var.environment_variables : {
      name  = k
      value = v
    }]

    # Secrets from AWS Secrets Manager
    secrets = [for k, v in var.secrets : {
      name      = k
      valueFrom = v
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.sandbox.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "sandbox"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }
  }])
}

###############################################################################
# Sandbox ECS Service Module (SQS Dispatch)
#
# Agent-runtime runs as an ECS Service worker pool. Session Service publishes
# to an SQS queue; idle worker tasks poll the queue, serve sessions, then
# terminate. ECS replaces terminated tasks to maintain desired count.
#
# Auto-scaling: target tracking on custom TaskUtilization metric with
# scale_in_enabled = false. See docs/design/sqs-sandbox-dispatch.md.
#
# Resources:
# - SQS queue + dead-letter queue for session dispatch
# - ECS Service (Fargate, awsvpc networking)
# - ECS task definition
# - Application Auto Scaling (target tracking, scale-out only)
# - Security group (ingress only from Session Service SG on port 8080)
# - IAM execution role (ECR pull, CloudWatch Logs, Secrets Manager)
# - IAM task role (S3, SQS, CloudWatch metrics)
# - CloudWatch log group
###############################################################################

# --------------------------------------------------------------------------- #
# SQS Queue — Session Dispatch
# --------------------------------------------------------------------------- #

resource "aws_sqs_queue" "sandbox_dlq" {
  name                      = "${var.name_prefix}-sandbox-requests-dlq"
  message_retention_seconds = 1209600 # 14 days
}

resource "aws_sqs_queue" "sandbox_requests" {
  name                       = "${var.name_prefix}-sandbox-requests"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 86400 # 1 day
  receive_wait_time_seconds  = 20    # Long polling

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.sandbox_dlq.arn
    maxReceiveCount     = 3
  })
}

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
# IAM — Execution Role (pulls images, writes logs, reads secrets)
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
      # SQS: poll and delete messages from the sandbox requests queue
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = aws_sqs_queue.sandbox_requests.arn
      },
      # CloudWatch: publish TaskUtilization metric for auto-scaling
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "Cowork/Sandbox"
          }
        }
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

    # Environment variables — includes SQS_QUEUE_URL for worker mode
    environment = concat(
      [for k, v in var.environment_variables : {
        name  = k
        value = v
      }],
      [
        { name = "SQS_QUEUE_URL", value = aws_sqs_queue.sandbox_requests.url },
        { name = "SANDBOX_SERVICE_NAME", value = "${var.name_prefix}-sandbox-workers" },
        { name = "ENVIRONMENT", value = var.environment },
      ]
    )

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
      startPeriod = 60
    }

    # Stop timeout — give sandbox time to sync workspace on SIGTERM
    stopTimeout = 120
  }])
}

# --------------------------------------------------------------------------- #
# ECS Service — Sandbox Workers
# --------------------------------------------------------------------------- #

resource "aws_ecs_service" "sandbox_workers" {
  name            = "${var.name_prefix}-sandbox-workers"
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.sandbox.arn
  desired_count   = var.min_capacity
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = var.private_subnet_ids
    security_groups = [aws_security_group.sandbox.id]
  }

  # Don't force new deployment on every apply — let auto-scaling manage count
  lifecycle {
    ignore_changes = [desired_count]
  }
}

# --------------------------------------------------------------------------- #
# Application Auto Scaling — Scale-Out Only (TaskUtilization)
# --------------------------------------------------------------------------- #

resource "aws_appautoscaling_target" "sandbox" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${var.ecs_cluster_name}/${aws_ecs_service.sandbox_workers.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "sandbox_utilization" {
  name               = "${var.name_prefix}-sandbox-utilization"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.sandbox.resource_id
  scalable_dimension = aws_appautoscaling_target.sandbox.scalable_dimension
  service_namespace  = aws_appautoscaling_target.sandbox.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.utilization_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    # Scale-out only — tasks self-terminate, ECS replaces to maintain desired
    disable_scale_in = true

    customized_metric_specification {
      metric_name = "TaskUtilization"
      namespace   = "Cowork/Sandbox"
      statistic   = "Average"

      dimensions {
        name  = "ServiceName"
        value = "${var.name_prefix}-sandbox-workers"
      }

      dimensions {
        name  = "Environment"
        value = var.environment
      }
    }
  }
}

# --------------------------------------------------------------------------- #
# CloudWatch Alarms
# --------------------------------------------------------------------------- #

resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "${var.name_prefix}-sandbox-dlq-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Sandbox DLQ has messages — failed session dispatches"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.sandbox_dlq.name
  }
}

###############################################################################
# Generic ECS Fargate Service Module
#
# Creates a Fargate service with:
# - Task definition (container, env vars, logging)
# - ECS service with desired count and health check grace period
# - ALB target group + listener rule (path-based routing)
# - IAM roles (task execution + task role)
# - CloudWatch log group
###############################################################################

# --------------------------------------------------------------------------- #
# CloudWatch Log Group
# --------------------------------------------------------------------------- #

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.service_name}"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

# --------------------------------------------------------------------------- #
# IAM — Task Execution Role (pulls images, writes logs)
# --------------------------------------------------------------------------- #

resource "aws_iam_role" "execution" {
  name = "${var.service_name}-execution"

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

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --------------------------------------------------------------------------- #
# IAM — Task Role (what the container can do at runtime)
# --------------------------------------------------------------------------- #

resource "aws_iam_role" "task" {
  name = "${var.service_name}-task"

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

  tags = var.tags
}

resource "aws_iam_role_policy" "task" {
  count = length(var.task_policy_statements) > 0 ? 1 : 0

  name = "${var.service_name}-task-policy"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = var.task_policy_statements
  })
}

# --------------------------------------------------------------------------- #
# Task Definition
# --------------------------------------------------------------------------- #

resource "aws_ecs_task_definition" "this" {
  family                   = var.service_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = var.service_name
    image     = var.container_image
    essential = true

    portMappings = [{
      containerPort = var.container_port
      protocol      = "tcp"
    }]

    environment = [for k, v in var.environment_variables : {
      name  = k
      value = v
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.this.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:${var.container_port}/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 10
    }
  }])

  tags = var.tags
}

# --------------------------------------------------------------------------- #
# ALB Target Group
# --------------------------------------------------------------------------- #

resource "aws_lb_target_group" "this" {
  name        = var.service_name
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = var.tags
}

# --------------------------------------------------------------------------- #
# ALB Listener Rule (path-based routing)
# --------------------------------------------------------------------------- #

resource "aws_lb_listener_rule" "this" {
  listener_arn = var.alb_listener_arn
  priority     = var.listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  condition {
    path_pattern {
      values = var.path_patterns
    }
  }

  tags = var.tags
}

# --------------------------------------------------------------------------- #
# ECS Service
# --------------------------------------------------------------------------- #

resource "aws_ecs_service" "this" {
  name            = var.service_name
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = var.service_name
    container_port   = var.container_port
  }

  health_check_grace_period_seconds = 60

  deployment_configuration {
    maximum_percent         = 200
    minimum_healthy_percent = 100
  }

  tags = var.tags
}

variable "service_name" {
  description = "Name of the ECS service (used for all resource naming)"
  type        = string
}

variable "container_image" {
  description = "Docker image URI (e.g. 123456789.dkr.ecr.us-east-1.amazonaws.com/approval-service:latest)"
  type        = string
}

variable "container_port" {
  description = "Port the container listens on"
  type        = number
  default     = 8000
}

variable "cpu" {
  description = "Fargate task CPU units (256, 512, 1024, 2048, 4096)"
  type        = number
  default     = 256
}

variable "memory" {
  description = "Fargate task memory in MiB (512, 1024, 2048, ...)"
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Number of running tasks"
  type        = number
  default     = 2
}

variable "environment_variables" {
  description = "Map of environment variables to set on the container"
  type        = map(string)
  default     = {}
}

variable "task_policy_statements" {
  description = "IAM policy statements for the task role (e.g. DynamoDB, S3 access)"
  type = list(object({
    Effect   = string
    Action   = list(string)
    Resource = list(string)
  }))
  default = []
}

# --- Networking ---

variable "vpc_id" {
  description = "VPC ID for target group"
  type        = string
}

variable "private_subnet_ids" {
  description = "Subnet IDs for Fargate tasks"
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security group IDs for Fargate tasks"
  type        = list(string)
}

# --- ALB ---

variable "ecs_cluster_id" {
  description = "ECS cluster ID"
  type        = string
}

variable "alb_listener_arn" {
  description = "ALB listener ARN for adding routing rules"
  type        = string
}

variable "listener_rule_priority" {
  description = "Priority for the ALB listener rule (lower = evaluated first)"
  type        = number
}

variable "path_patterns" {
  description = "URL path patterns for ALB routing (e.g. [\"/approvals\", \"/approvals/*\"])"
  type        = list(string)
}

# --- Observability ---

variable "aws_region" {
  description = "AWS region for CloudWatch logs"
  type        = string
  default     = "us-east-1"
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30
}

# --- Tags ---

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

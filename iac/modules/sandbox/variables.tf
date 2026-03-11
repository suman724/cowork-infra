###############################################################################
# Sandbox Module Variables
###############################################################################

# --- Naming ---

variable "name_prefix" {
  description = "Resource name prefix (e.g. cowork-dev)"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

# --- Container ---

variable "container_image" {
  description = "Docker image URI for agent-runtime sandbox"
  type        = string
}

variable "cpu" {
  description = "Fargate task CPU units (256, 512, 1024, 2048, 4096)"
  type        = number
  default     = 512
}

variable "memory" {
  description = "Fargate task memory in MiB (must be valid for chosen CPU)"
  type        = number
  default     = 1024
}

variable "environment_variables" {
  description = "Static environment variables for the sandbox container"
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Secrets from AWS Secrets Manager (name → secret ARN)"
  type        = map(string)
  default     = {}
}

# --- Networking ---

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "session_service_sg_id" {
  description = "Security group ID of the Session Service ECS tasks (for ingress rules)"
  type        = string
}

# --- IAM / Storage ---

variable "artifacts_bucket_arn" {
  description = "ARN of the workspace artifacts S3 bucket"
  type        = string
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

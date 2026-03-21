###############################################################################
# Dev Environment Variables
###############################################################################

# --- Environment ---

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

# --- Networking ---

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones for subnets"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

# --- Observability ---

variable "log_level" {
  description = "Log level for all services"
  type        = string
  default     = "info"
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30
}

# --- Container Images ---

variable "session_service_image" {
  description = "Docker image for session-service"
  type        = string
}

variable "policy_service_image" {
  description = "Docker image for policy-service"
  type        = string
}

variable "workspace_service_image" {
  description = "Docker image for workspace-service"
  type        = string
}

variable "approval_service_image" {
  description = "Docker image for approval-service"
  type        = string
}

# --- Approval Service Sizing ---

variable "approval_service_cpu" {
  description = "CPU units for approval service tasks"
  type        = number
  default     = 256
}

variable "approval_service_memory" {
  description = "Memory (MiB) for approval service tasks"
  type        = number
  default     = 512
}

variable "approval_service_desired_count" {
  description = "Number of approval service tasks"
  type        = number
  default     = 2
}

# --- Sandbox (Agent Runtime) ---

variable "sandbox_image" {
  description = "Docker image for agent-runtime sandbox"
  type        = string
}

variable "sandbox_cpu" {
  description = "CPU units for sandbox tasks (512 recommended for agent loop)"
  type        = number
  default     = 512
}

variable "sandbox_memory" {
  description = "Memory (MiB) for sandbox tasks (1024 recommended for agent loop)"
  type        = number
  default     = 1024
}

variable "sandbox_min_capacity" {
  description = "Minimum sandbox worker tasks (always running)"
  type        = number
  default     = 1
}

variable "sandbox_max_capacity" {
  description = "Maximum sandbox worker tasks"
  type        = number
  default     = 5
}

variable "sandbox_utilization_target" {
  description = "Target TaskUtilization % for auto-scaling (0-100)"
  type        = number
  default     = 70
}

variable "llm_gateway_endpoint" {
  description = "LLM Gateway endpoint URL (passed to sandbox containers)"
  type        = string
}

variable "llm_gateway_auth_token_arn" {
  description = "ARN of the Secrets Manager secret containing LLM Gateway auth token"
  type        = string
}

###############################################################################
# Dev Environment Outputs
###############################################################################

# --- Shared Infrastructure ---

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "alb_dns_name" {
  description = "ALB DNS name (use as base URL for all services)"
  value       = aws_lb.main.dns_name
}

output "alb_arn" {
  description = "ALB ARN"
  value       = aws_lb.main.arn
}

# --- DynamoDB Tables ---

output "approvals_table_name" {
  description = "Approvals DynamoDB table name"
  value       = module.approvals_table.table_name
}

output "approvals_table_arn" {
  description = "Approvals DynamoDB table ARN"
  value       = module.approvals_table.table_arn
}

output "sessions_table_name" {
  description = "Sessions DynamoDB table name"
  value       = module.sessions_table.table_name
}

output "tasks_table_name" {
  description = "Tasks DynamoDB table name"
  value       = module.tasks_table.table_name
}

output "workspaces_table_name" {
  description = "Workspaces DynamoDB table name"
  value       = module.workspaces_table.table_name
}

output "artifacts_table_name" {
  description = "Artifacts DynamoDB table name"
  value       = module.artifacts_table.table_name
}

# --- S3 ---

output "artifacts_bucket_name" {
  description = "S3 bucket for workspace artifacts"
  value       = aws_s3_bucket.artifacts.id
}

# --- Service Endpoints ---

output "approval_service_name" {
  description = "Approval service ECS service name"
  value       = module.approval_service.service_name
}

output "session_service_name" {
  description = "Session service ECS service name"
  value       = module.session_service.service_name
}

output "workspace_service_name" {
  description = "Workspace service ECS service name"
  value       = module.workspace_service.service_name
}

output "policy_service_name" {
  description = "Policy service ECS service name"
  value       = module.policy_service.service_name
}

# --- Sandbox ---

output "sandbox_task_definition_arn" {
  description = "Sandbox ECS task definition ARN (used by Session Service RunTask)"
  value       = module.sandbox.task_definition_arn
}

output "sandbox_security_group_id" {
  description = "Sandbox security group ID"
  value       = module.sandbox.security_group_id
}

output "sandbox_log_group_name" {
  description = "Sandbox CloudWatch log group name"
  value       = module.sandbox.log_group_name
}

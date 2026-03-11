###############################################################################
# Sandbox Module Outputs
###############################################################################

output "task_definition_arn" {
  description = "ARN of the sandbox ECS task definition"
  value       = aws_ecs_task_definition.sandbox.arn
}

output "task_definition_family" {
  description = "Family name of the sandbox task definition"
  value       = aws_ecs_task_definition.sandbox.family
}

output "security_group_id" {
  description = "Security group ID for sandbox containers"
  value       = aws_security_group.sandbox.id
}

output "task_role_arn" {
  description = "ARN of the sandbox task IAM role"
  value       = aws_iam_role.task.arn
}

output "execution_role_arn" {
  description = "ARN of the sandbox execution IAM role"
  value       = aws_iam_role.execution.arn
}

output "log_group_name" {
  description = "CloudWatch log group name"
  value       = aws_cloudwatch_log_group.sandbox.name
}

output "log_group_arn" {
  description = "CloudWatch log group ARN"
  value       = aws_cloudwatch_log_group.sandbox.arn
}

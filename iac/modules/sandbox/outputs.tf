###############################################################################
# Sandbox Module Outputs
###############################################################################

# --- SQS ---

output "sqs_queue_url" {
  description = "URL of the sandbox session dispatch SQS queue"
  value       = aws_sqs_queue.sandbox_requests.url
}

output "sqs_queue_arn" {
  description = "ARN of the sandbox session dispatch SQS queue"
  value       = aws_sqs_queue.sandbox_requests.arn
}

output "sqs_dlq_url" {
  description = "URL of the sandbox DLQ"
  value       = aws_sqs_queue.sandbox_dlq.url
}

# --- ECS ---

output "service_name" {
  description = "Name of the sandbox ECS Service"
  value       = aws_ecs_service.sandbox_workers.name
}

output "task_definition_arn" {
  description = "ARN of the sandbox ECS task definition"
  value       = aws_ecs_task_definition.sandbox.arn
}

output "task_definition_family" {
  description = "Family name of the sandbox task definition"
  value       = aws_ecs_task_definition.sandbox.family
}

# --- Security ---

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

# --- Observability ---

output "log_group_name" {
  description = "CloudWatch log group name"
  value       = aws_cloudwatch_log_group.sandbox.name
}

output "log_group_arn" {
  description = "CloudWatch log group ARN"
  value       = aws_cloudwatch_log_group.sandbox.arn
}

# Dev environment variable values
#
# Container images — update these after pushing to ECR.

environment = "dev"
aws_region  = "us-east-1"

session_service_image   = "ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/cowork-session-service:latest"
policy_service_image    = "ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/cowork-policy-service:latest"
workspace_service_image = "ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/cowork-workspace-service:latest"
approval_service_image  = "ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/cowork-approval-service:latest"

# Approval service sizing (dev defaults are small)
approval_service_cpu           = 256
approval_service_memory        = 512
approval_service_desired_count = 1

# Sandbox (agent-runtime)
sandbox_image              = "ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/cowork-agent-runtime:latest"
sandbox_cpu                = 512
sandbox_memory             = 1024
llm_gateway_endpoint       = "https://api.anthropic.com/v1/"
llm_gateway_auth_token_arn = "arn:aws:secretsmanager:us-east-1:ACCOUNT_ID:secret:cowork-dev-llm-gateway-token"

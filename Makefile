.PHONY: help fmt validate plan-dev plan-staging plan-prod apply-dev apply-staging apply-prod lint-docs clean

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

fmt: ## Format all Terraform files
	terraform fmt -recursive iac/

fmt-check: ## Check Terraform formatting
	terraform fmt -recursive -check iac/

validate: ## Validate Terraform configuration (dev)
	cd iac/environments/dev && terraform init -backend=false && terraform validate

plan-dev: ## Plan for dev environment
	cd iac/environments/dev && terraform plan -out=tfplan

plan-staging: ## Plan for staging environment
	cd iac/environments/staging && terraform plan -out=tfplan

plan-prod: ## Plan for prod environment
	cd iac/environments/prod && terraform plan -out=tfplan

apply-dev: ## Apply for dev environment
	cd iac/environments/dev && terraform apply tfplan

apply-staging: ## Apply for staging environment
	cd iac/environments/staging && terraform apply tfplan

apply-prod: ## Apply for prod environment (requires approval)
	cd iac/environments/prod && terraform apply tfplan

lint-docs: ## Lint markdown documentation
	@echo "Markdown lint not configured yet"

clean: ## Remove .terraform directories and plan files
	find iac/ -type d -name ".terraform" -exec rm -rf {} + 2>/dev/null || true
	find iac/ -name "tfplan" -delete 2>/dev/null || true
	find iac/ -name ".terraform.lock.hcl" -delete 2>/dev/null || true

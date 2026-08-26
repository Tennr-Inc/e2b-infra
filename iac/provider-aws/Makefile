ENV := $(shell cat ../../.last_used_env || echo "not-set")
ENV_FILE := ../../.env.${ENV}

-include ${ENV_FILE}

TF ?= $(shell command -v tofu 2>/dev/null || command -v terraform 2>/dev/null)
TF_VAR_FILE := ./.terraform.${ENV}.tfvars
TF_VAR_FILE_ARG := $(if $(wildcard $(TF_VAR_FILE)),-var-file=$(TF_VAR_FILE))
TERRAFORM_STATE_BUCKET ?= $(AWS_ACCOUNT_ID)-terraform-state
TEMPLATE_BUCKET_LOCATION ?= $(AWS_REGION)

BUCKET_PREFIX ?= $(PREFIX)$(AWS_ACCOUNT_ID)-

SKIP_FMT ?= false
define tf_fmt
$(if $(filter true,$(SKIP_FMT)),,$(TF) fmt -recursive)
endef

# Set the terraform environment variable only if the environment variable is set
# Strip the passed variable name (it's space sensitive) and check if the variable is set, if yes return TF_VAR_<variable_name>=<value> with the variable name in lower case
define tfvar
$(if $(value $(strip $(1))), TF_VAR_$(shell echo $(strip $(1)) | tr A-Z a-z)=$($(strip $(1))))
endef

tf_vars := AWS_PROFILE=$(AWS_PROFILE) AWS_REGION=$(AWS_REGION) \
	TF_VAR_environment=$(TERRAFORM_ENVIRONMENT) \
	$(call tfvar, PREFIX) \
	$(call tfvar, DOMAIN_NAME) \
	$(call tfvar, INGRESS_CERTIFICATE_ARN) \
	$(call tfvar, INGRESS_CERTIFICATE_VALIDATION_ZONE_ID) \
	$(call tfvar, INGRESS_ALLOWED_CIDR_BLOCKS) \
	$(call tfvar, INGRESS_ALLOWED_SECURITY_GROUP_IDS) \
	$(call tfvar, ENABLE_ALB_DELETION_PROTECTION) \
	$(call tfvar, BUCKET_PREFIX) \
	$(call tfvar, VPC_CIDR) \
	$(call tfvar, VPC_AVAILABILITY_ZONES) \
	$(call tfvar, VPC_PUBLIC_SUBNETS) \
	$(call tfvar, VPC_PRIVATE_SUBNETS) \
	$(call tfvar, VPC_ELASTICACHE_SUBNETS) \
	$(call tfvar, USE_INSTANCE_CONNECT) \
	$(call tfvar, PEER_VPC_ID) \
	$(call tfvar, PEER_VPC_CIDR) \
	$(call tfvar, PEER_ROUTE_TABLE_IDS) \
	$(call tfvar, CLIENT_CLUSTER_SIZE) \
	$(call tfvar, CLIENT_SERVER_MACHINE_TYPE) \
	$(call tfvar, CLIENT_SERVER_NESTED_VIRTUALIZATION) \
	$(call tfvar, CLICKHOUSE_CLUSTER_SIZE) \
	$(call tfvar, REDIS_INSTANCE_TYPE) \
	$(call tfvar, REDIS_MANAGED) \
	$(call tfvar, REDIS_REPLICA_SIZE) \
	$(call tfvar, POSTGRES_ENGINE_VERSION) \
	$(call tfvar, POSTGRES_ADMIN_INGRESS_SECURITY_GROUP_IDS) \
	$(call tfvar, POSTGRES_INSTANCE_CLASS) \
	$(call tfvar, POSTGRES_ALLOCATED_STORAGE) \
	$(call tfvar, POSTGRES_MAX_ALLOCATED_STORAGE) \
	$(call tfvar, POSTGRES_MULTI_AZ) \
	$(call tfvar, POSTGRES_BACKUP_RETENTION_PERIOD) \
	$(call tfvar, POSTGRES_DELETION_PROTECTION) \
	$(call tfvar, POSTGRES_SKIP_FINAL_SNAPSHOT) \
	$(call tfvar, DOCKER_REVERSE_PROXY_ENABLED) \
	$(call tfvar, API_CLUSTER_SIZE) \
	$(call tfvar, API_INTERNAL_GRPC_PORT) \
	$(call tfvar, API_SERVER_MACHINE_TYPE) \
	$(call tfvar, CLIENT_PROXY_COUNT) \
	$(call tfvar, INGRESS_COUNT) \
	$(call tfvar, BUILD_CLUSTER_SIZE) \
	$(call tfvar, BUILD_SERVER_MACHINE_TYPE) \
	$(call tfvar, BUILD_SERVER_NESTED_VIRTUALIZATION) \
	$(call tfvar, AWS_ACCOUNT_ID) \
	$(call tfvar, AWS_REGION) \
	$(call tfvar, ENABLE_OTEL_ROUTER_LOGS) \
	$(call tfvar, OTEL_ROUTER_HTTP_PORT) \
	$(call tfvar, ENABLE_OTEL_ROUTER_METRICS) \
	$(call tfvar, OTEL_ROUTER_GRPC_PORT) \
	$(call tfvar, DB_MAX_OPEN_CONNECTIONS) \
	$(call tfvar, DB_MIN_IDLE_CONNECTIONS) \
	$(call tfvar, AUTH_DB_MAX_OPEN_CONNECTIONS) \
	$(call tfvar, AUTH_DB_MIN_IDLE_CONNECTIONS) \
	$(call tfvar, ALLOW_SANDBOX_INTERNAL_CIDRS)

.PHONY: provider-login
provider-login: verify-account
	aws ecr get-login-password --region $(AWS_REGION) --profile $(AWS_PROFILE) | docker login --username AWS --password-stdin $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com

.PHONY: verify-account
verify-account:
	@test -n "$(AWS_ACCOUNT_ID)" || (echo "AWS_ACCOUNT_ID is required" && exit 1)
	@test -n "$(AWS_PROFILE)" || (echo "AWS_PROFILE is required" && exit 1)
	@actual_account=$$(aws sts get-caller-identity --profile "$(AWS_PROFILE)" --query Account --output text); \
		test "$$actual_account" = "$(AWS_ACCOUNT_ID)" || \
		(echo "Refusing to continue: AWS profile $(AWS_PROFILE) resolves to $$actual_account, expected $(AWS_ACCOUNT_ID)" && exit 1)

.PHONY: switch
switch: verify-account
	$(tf_vars) $(TF) init -input=false -upgrade -reconfigure -backend-config="bucket=$(TERRAFORM_STATE_BUCKET)"

.PHONY: init
init: verify-account
	# Create S3 bucket for Terraform state if it doesn't exist
	# us-east-1 requires omitting LocationConstraint; all other regions require it
	@if [ "$(TEMPLATE_BUCKET_LOCATION)" = "us-east-1" ]; then \
		aws s3api create-bucket --bucket $(TERRAFORM_STATE_BUCKET) --region $(TEMPLATE_BUCKET_LOCATION) --profile $(AWS_PROFILE) 2>/dev/null || true; \
	else \
		aws s3api create-bucket --bucket $(TERRAFORM_STATE_BUCKET) --region $(TEMPLATE_BUCKET_LOCATION) --profile $(AWS_PROFILE) --create-bucket-configuration LocationConstraint=$(TEMPLATE_BUCKET_LOCATION) 2>/dev/null || true; \
	fi
	aws s3api put-public-access-block --bucket $(TERRAFORM_STATE_BUCKET) --profile $(AWS_PROFILE) --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
	aws s3api put-bucket-encryption --bucket $(TERRAFORM_STATE_BUCKET) --profile $(AWS_PROFILE) --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
	aws s3api put-bucket-versioning --bucket $(TERRAFORM_STATE_BUCKET) --profile $(AWS_PROFILE) --versioning-configuration Status=Enabled
	$(tf_vars) $(TF) init -upgrade -reconfigure -backend-config="bucket=${TERRAFORM_STATE_BUCKET}"
	$(tf_vars) $(TF) apply -target=module.init -input=false -compact-warnings

.PHONY: plan
plan: verify-account
	@ printf "Planning Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	@ $(call tf_fmt)
	@ $(tf_vars) $(TF) plan $(TF_VAR_FILE_ARG) -out=.tfplan.$(ENV) -input=false -compact-warnings -parallelism=20

.PHONY: request-certificate
request-certificate: verify-account
	@test -z "$(INGRESS_CERTIFICATE_ARN)" || (echo "INGRESS_CERTIFICATE_ARN is already set; Terraform will use that certificate" && exit 1)
	@if [ -n "$(INGRESS_CERTIFICATE_VALIDATION_ZONE_ID)" ]; then \
		$(tf_vars) $(TF) apply $(TF_VAR_FILE_ARG) -target=aws_acm_certificate_validation.ingress -auto-approve -input=false -compact-warnings; \
	else \
		$(tf_vars) $(TF) apply $(TF_VAR_FILE_ARG) -target=aws_acm_certificate.ingress -auto-approve -input=false -compact-warnings; \
	fi
	@ $(tf_vars) $(TF) output -json certificate_dns_validation_records

.PHONY: certificate-validation-records
certificate-validation-records: verify-account
	@ $(tf_vars) $(TF) output -json certificate_dns_validation_records

plan_only_jobs_moved_targets = -target="random_password.volume_token_key" -target="module.nomad.random_password.volume_token_key"

.PHONY: plan-only-jobs
plan-only-jobs: verify-account
	@ printf "Planning Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	$(call tf_fmt)
	@ $(tf_vars) $(TF) plan $(TF_VAR_FILE_ARG) -out=.tfplan.$(ENV) -input=false -compact-warnings -parallelism=20 -target=module.nomad $(plan_only_jobs_moved_targets)

.PHONY: plan-without-jobs
plan-without-jobs: verify-account
	@ printf "Planning Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	$(eval TARGET := $(shell cat main.tf | grep "^module" | awk '{print $$2}' | tr ' ' '\n' | grep -v -e "nomad" | awk '{print "-target=module." $$0 ""}' | xargs))
	@ $(tf_vars) $(TF) plan $(TF_VAR_FILE_ARG) -out=.tfplan.$(ENV) -input=false -compact-warnings -parallelism=20 $(TARGET)

.PHONY: apply
apply: verify-account
	@ printf "Applying Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	@ $(tf_vars) $(TF) apply -auto-approve -input=false -compact-warnings -parallelism=20 .tfplan.$(ENV)

.PHONY: state-migrate
state-migrate:
	@ printf "Running Terraform state migrations for env: $(ENV)\n\n"
	@ $(tf_vars) $(TF) state mv 'module.nomad.random_password.volume_token_key' 'random_password.volume_token_key' || true

.PHONY: apply-init
apply-init: verify-account
	@ $(tf_vars) $(TF) apply $(TF_VAR_FILE_ARG) -target=module.init -auto-approve -input=false -compact-warnings

.PHONY: move
move:
	@ printf "Moving resource for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	@ $(tf_vars) $(TF) state mv "$(SOURCE)" "$(TARGET)" -no-color

.PHONY: destroy
destroy:
	@ printf "Destroying Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	@ $(tf_vars) $(TF) destroy $(TF_VAR_FILE_ARG)

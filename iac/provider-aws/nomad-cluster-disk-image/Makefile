ENV := $(shell cat ../../../.last_used_env || echo "not-set")
-include ../../../.env.${ENV}

TF ?= $(shell command -v tofu 2>/dev/null || command -v terraform 2>/dev/null)
EBS_KMS_KEY_ARN ?= $(shell AWS_PROFILE="$(AWS_PROFILE)" AWS_REGION="$(AWS_REGION)" $(TF) -chdir=.. output -raw ebs_kms_key_arn 2>/dev/null)

init:
	packer init -upgrade .

build:
	@test -n "$(EBS_KMS_KEY_ARN)" || (echo "Missing ebs_kms_key_arn; run make init before building the AMI" && exit 1)
	packer build \
		$(if $(PACKER_CONSUL_VERSION),-var "consul_version=$(PACKER_CONSUL_VERSION)") \
		$(if $(PACKER_NOMAD_VERSION),-var "nomad_version=$(PACKER_NOMAD_VERSION)") \
		$(if $(PACKER_VPC_ID),-var "vpc_id=$(PACKER_VPC_ID)") \
		$(if $(PACKER_SUBNET_ID),-var "subnet_id=$(PACKER_SUBNET_ID)") \
		$(if $(PACKER_SOURCE_AMI_FILTER_NAME),-var "source_ami_filter_name=$(PACKER_SOURCE_AMI_FILTER_NAME)") \
		-var "prefix=$(PREFIX)" \
		-var "aws_region=$(AWS_REGION)" \
		-var "aws_profile=$(AWS_PROFILE)" \
		-var "ebs_kms_key_arn=$(EBS_KMS_KEY_ARN)" \
		.

format:
	packer fmt .

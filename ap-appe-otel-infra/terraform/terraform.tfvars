###############################################################################
# terraform.tfvars — Environment Values
# ⚠  REQUIRED manual edit: set key_name before running terraform apply
###############################################################################

# AWS Configuration
aws_region  = "us-east-1"
aws_az      = "us-east-1a"
account_id  = "584554046133"

# Existing VPC (DO NOT change)
vpc_id = "vpc-0018aa4902fa67a2c"

# New ECS Cluster
cluster_name   = "ap-appe-ecs-otel"
instance_type  = "t3.xlarge"
instance_count = 2

# ⚠ REQUIRED: Set to your actual EC2 key pair name in us-east-1
# Find existing pairs: aws ec2 describe-key-pairs --region us-east-1 --query 'KeyPairs[*].KeyName'
# Create new pair:     aws ec2 create-key-pair --key-name ap-appe-otel-key --query 'KeyMaterial' --output text > ap-appe-otel-key.pem
key_name = "grafana-stack-lgtm"

# New subnet CIDR (verify no overlap with existing subnets)
# Check existing: aws ec2 describe-subnets --filters "Name=vpc-id,Values=vpc-0018aa4902fa67a2c" --query 'Subnets[*].CidrBlock'
subnet_id = "subnet-0548c87344ac6f8a2"

# S3 bucket (globally unique, no account number)
s3_bucket = "ap-appe-otel-observability-store"

# ECR base URI
ecr_base  = "584554046133.dkr.ecr.us-east-1.amazonaws.com/ap-appe-otel"
image_tag = "latest"

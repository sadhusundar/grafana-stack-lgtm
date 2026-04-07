###############################################################################
# variables.tf — All Input Variables
###############################################################################

# ── AWS Environment ───────────────────────────────────────────────────────────
variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "aws_az" {
  description = "Availability Zone for subnet and EC2 instances"
  type        = string
  default     = "us-east-1a"
}

variable "account_id" {
  description = "AWS account ID (used for ECR URIs and IAM ARNs)"
  type        = string
  default     = "584554046133"
}

# ── Existing VPC (DO NOT recreate) ───────────────────────────────────────────
variable "vpc_id" {
  description = "Existing VPC ID — do NOT recreate"
  type        = string
  default     = "vpc-0018aa4902fa67a2c"
}

# ── ECS Cluster ───────────────────────────────────────────────────────────────
variable "cluster_name" {
  description = "New ECS cluster name"
  type        = string
  default     = "ap-appe-ecs-otel"
}

# ── EC2 Instances ─────────────────────────────────────────────────────────────
variable "instance_type" {
  description = "EC2 instance type for ECS container instances"
  type        = string
  default     = "t3.xlarge"
}

variable "instance_count" {
  description = "Number of EC2 instances in the ASG"
  type        = number
  default     = 2
}

variable "key_name" {
  description = "EC2 Key Pair name for SSH access (must exist in us-east-1)"
  type        = string
  # REQUIRED: Set in terraform.tfvars or via -var flag
  # Example: key_name = "my-keypair-us-east-1"
}

# ── Networking ────────────────────────────────────────────────────────────────
variable "subnet_id" {
  description = "Existing subnet ID to use"
  type        = string
}

# ── Storage ───────────────────────────────────────────────────────────────────
variable "s3_bucket" {
  description = "Globally unique S3 bucket name for Loki/Tempo/Thanos (no account number)"
  type        = string
  default     = "ap-appe-otel-observability-store"
}

# ── Container Images ──────────────────────────────────────────────────────────
variable "ecr_base" {
  description = "ECR base URI without trailing slash"
  type        = string
  default     = "584554046133.dkr.ecr.us-east-1.amazonaws.com/ap-appe-otel"
}

# ── Service Versions (update to match your pushed image tags) ─────────────────
variable "image_tag" {
  description = "Docker image tag for all services"
  type        = string
  default     = "latest"
}

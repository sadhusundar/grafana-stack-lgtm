###############################################################################
# main.tf — Provider & Backend Configuration
# Project : ap-appe-ecs-otel (Observability Stack)
# Region  : us-east-1  |  AZ: us-east-1a
# Account : 584554046133
###############################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # ── OPTIONAL: enable if you have an S3 state backend ─────────────────────
  # backend "s3" {
  #   bucket         = "ap-appe-tf-state-otel"   # create this bucket manually first
  #   key            = "observability/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "ap-appe-tf-locks"        # optional, for state locking
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "ap-appe-otel"
      Environment = "production"
      ManagedBy   = "terraform"
    }
  }
}

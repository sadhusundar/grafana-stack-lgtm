###############################################################################
# vpc_endpoints.tf — VPC Interface & Gateway Endpoints
#
# Private subnets have no NAT gateway by default on this VPC, so we create
# VPC endpoints to allow ECS tasks to reach AWS services without public routing.
#
# We use data sources to check for existing endpoints first.
# If they exist (from other subnets/route-tables), we skip creation.
###############################################################################

# ── Check for existing endpoints ─────────────────────────────────────────────
data "aws_vpc_endpoint" "existing_s3" {
  vpc_id       = var.vpc_id
  service_name = "com.amazonaws.${var.aws_region}.s3"
  state        = "available"
}

# ── S3 Gateway Endpoint (free, high throughput for ECR layer pulls + storage) ─
# Only create if none exists. We associate with our new route table.
resource "aws_vpc_endpoint" "s3" {
  count = length(data.aws_vpc_endpoint.existing_s3.id) == 0 ? 1 : 0

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [data.aws_route_table.otel_private.id]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = ["s3:*"]
      Resource  = ["*"]
    }]
  })

  tags = {
    Name = "ap-appe-otel-s3-endpoint"
  }
}

# ── If S3 endpoint exists, associate our route table with it ─────────────────
# (Cannot be done via Terraform if endpoint was created outside Terraform —
#  handle via aws cli in scripts/03-vpc-endpoints.sh)

# ── ECR API Interface Endpoint ─────────────────────────────────────────────────
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [data.aws_subnet.otel_private.id]
  security_group_ids  = [aws_security_group.ecs_tasks.id]
  private_dns_enabled = true

  tags = {
    Name = "ap-appe-otel-ecr-api-endpoint"
  }
}

# ── ECR Docker (DKR) Interface Endpoint ───────────────────────────────────────
resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [data.aws_subnet.otel_private.id]
  security_group_ids  = [aws_security_group.ecs_tasks.id]
  private_dns_enabled = true

  tags = {
    Name = "ap-appe-otel-ecr-dkr-endpoint"
  }
}

# ── CloudWatch Logs Interface Endpoint ────────────────────────────────────────
resource "aws_vpc_endpoint" "cloudwatch_logs" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [data.aws_subnet.otel_private.id]
  security_group_ids  = [aws_security_group.ecs_tasks.id]
  private_dns_enabled = true

  tags = {
    Name = "ap-appe-otel-cwlogs-endpoint"
  }
}

# ── SSM Interface Endpoint (for EC2 SSM Session Manager access) ───────────────
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [data.aws_subnet.otel_private.id]
  security_group_ids  = [aws_security_group.ecs_instances.id]
  private_dns_enabled = true

  tags = {
    Name = "ap-appe-otel-ssm-endpoint"
  }
}

resource "aws_vpc_endpoint" "ssm_messages" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [data.aws_subnet.otel_private.id]
  security_group_ids  = [aws_security_group.ecs_instances.id]
  private_dns_enabled = true

  tags = {
    Name = "ap-appe-otel-ssmmessages-endpoint"
  }
}

resource "aws_vpc_endpoint" "ec2_messages" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [data.aws_subnet.otel_private.id]
  security_group_ids  = [aws_security_group.ecs_instances.id]
  private_dns_enabled = true

  tags = {
    Name = "ap-appe-otel-ec2messages-endpoint"
  }
}

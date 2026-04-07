###############################################################################
# networking.tf — New Subnet + Security Groups
# VPC  : vpc-0018aa4902fa67a2c  (existing — do NOT recreate)
# AZ   : us-east-1a
###############################################################################

# ── Data: look up the existing VPC so we inherit DNS settings ─────────────────
data "aws_vpc" "main" {
  id = var.vpc_id
}

# ADD this instead:
data "aws_subnet" "otel_private" {
  id = var.subnet_id
}

data "aws_route_table" "otel_private" {
  subnet_id = data.aws_subnet.otel_private.id
}

###############################################################################
# Security Groups
###############################################################################

# ── SG 1: ECS Container Instances (EC2 hosts) ─────────────────────────────────
resource "aws_security_group" "ecs_instances" {
  name        = "ap-appe-otel-ecs-instances-sg"
  description = "Security group for ECS EC2 container instances"
  vpc_id      = var.vpc_id

  # --- INBOUND ---

  # SSH — restrict to your bastion/VPN IP in production
  # ⚠ Change 0.0.0.0/0 to your actual admin CIDR
  ingress {
    description = "SSH from admin network"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # TODO: restrict to your admin CIDR
  }

  # Allow all inbound from the VPC CIDR (internal service communication)
  ingress {
    description = "All traffic from VPC CIDR"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  # Allow ECS tasks on dynamic port range (ECS bridge mode ephemeral ports)
  ingress {
    description = "ECS ephemeral ports"
    from_port   = 32768
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  # --- OUTBOUND ---
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ap-appe-otel-ecs-instances-sg"
  }
}

# ── SG 2: ECS Tasks (awsvpc mode — each task gets its own ENI) ────────────────
resource "aws_security_group" "ecs_tasks" {
  name        = "ap-appe-otel-ecs-tasks-sg"
  description = "Security group for ECS tasks running in awsvpc mode"
  vpc_id      = var.vpc_id

  # --- INBOUND (open-source observability ports) ---

  # Prometheus scrape / API
  ingress {
    description = "Prometheus HTTP"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  # Loki HTTP API + push endpoint
  ingress {
    description = "Loki HTTP"
    from_port   = 3100
    to_port     = 3100
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  # Loki gRPC
  ingress {
    description = "Loki gRPC"
    from_port   = 9095
    to_port     = 9095
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  # Tempo HTTP
  ingress {
    description = "Tempo HTTP"
    from_port   = 3200
    to_port     = 3200
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  # OTLP gRPC (Tempo ingestion)
  ingress {
    description = "OTLP gRPC"
    from_port   = 4317
    to_port     = 4317
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  # OTLP HTTP (Tempo ingestion)
  ingress {
    description = "OTLP HTTP"
    from_port   = 4318
    to_port     = 4318
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  # Grafana
  ingress {
    description = "Grafana UI"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  # Thanos sidecar gRPC (Store API)
  ingress {
    description = "Thanos gRPC"
    from_port   = 10901
    to_port     = 10901
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  # Thanos HTTP (Query UI / metrics)
  ingress {
    description = "Thanos HTTP"
    from_port   = 10902
    to_port     = 10902
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  # Self-referencing: all tasks can talk to each other
  ingress {
    description = "Inter-task communication"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  # --- OUTBOUND ---
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ap-appe-otel-ecs-tasks-sg"
  }
}

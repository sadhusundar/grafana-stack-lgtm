###############################################################################
# cluster.tf — ECS Cluster, Launch Template, ASG, Capacity Provider
#
# Creates:
#   - ECS Cluster: ap-appe-ecs-otel
#   - Launch Template with ECS-optimized AMI (Amazon Linux 2)
#   - Auto Scaling Group: 2 × t3.xlarge in us-east-1a
#   - ECS Capacity Provider attached to ASG
###############################################################################

# ── ECS-Optimized AMI (Amazon Linux 2 — latest) ───────────────────────────────
data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended/image_id"
}

# ── ECS Cluster ───────────────────────────────────────────────────────────────
resource "aws_ecs_cluster" "main" {
  name = var.cluster_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = var.cluster_name
  }
}

# ── EC2 Launch Template ───────────────────────────────────────────────────────
resource "aws_launch_template" "ecs" {
  name_prefix   = "ap-appe-otel-ecs-lt-"
  description   = "Launch template for ECS EC2 container instances"
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = var.instance_type
  key_name      = var.key_name

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2.arn
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.ecs_instances.id]
    subnet_id                   = aws_subnet.otel_private.id
    delete_on_termination       = true
  }

  # ECS agent bootstrap + host directory preparation
  user_data = base64encode(templatefile("${path.module}/templates/user_data.sh.tpl", {
    cluster_name = var.cluster_name
  }))

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 100     # GB — enough for Docker images + host volumes
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"   # IMDSv2 enforced
    http_put_response_hop_limit = 2            # Required for ECS tasks to reach IMDS
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "ap-appe-otel-ecs-instance"
      Project     = "ap-appe-otel"
      Environment = "production"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "ap-appe-otel-ecs-volume"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── Auto Scaling Group ────────────────────────────────────────────────────────
resource "aws_autoscaling_group" "ecs" {
  name                = "ap-appe-otel-asg"
  min_size            = var.instance_count
  max_size            = var.instance_count
  desired_capacity    = var.instance_count
  vpc_zone_identifier = [aws_subnet.otel_private.id]

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  health_check_type         = "EC2"
  health_check_grace_period = 300
  protect_from_scale_in     = false

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }
  tag {
    key                 = "Name"
    value               = "ap-appe-otel-ecs-instance"
    propagate_at_launch = true
  }
  tag {
    key                 = "Project"
    value               = "ap-appe-otel"
    propagate_at_launch = true
  }
}

# ── ECS Capacity Provider ─────────────────────────────────────────────────────
resource "aws_ecs_capacity_provider" "ec2" {
  name = "ap-appe-otel-ec2-cp"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs.arn
    managed_termination_protection = "DISABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 100
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 2
    }
  }

  tags = {
    Name = "ap-appe-otel-ec2-cp"
  }
}

# ── Attach Capacity Provider to Cluster ──────────────────────────────────────
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = [aws_ecs_capacity_provider.ec2.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2.name
    weight            = 1
    base              = 1
  }
}

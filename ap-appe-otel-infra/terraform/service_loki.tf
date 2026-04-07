###############################################################################
# service_loki.tf — Loki Task & Service
#
# S3 backend for chunks/ruler. Host-mounted /data/loki for WAL, index, cache.
# Runs as root (user=0) to write to the host-mounted volume.
###############################################################################

resource "aws_ecs_task_definition" "loki" {
  family                   = "ap-appe-otel-loki"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  task_role_arn            = aws_iam_role.ecs_task.arn
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  cpu                      = "512"
  memory                   = "2048"

  volume {
    name      = "loki-data"
    host_path = "/data/loki"
  }

  container_definitions = jsonencode([
    {
      name      = "loki"
      image     = "${var.ecr_base}/loki:${var.image_tag}"
      essential = true
      user      = "0"  # root — required to write to host-mounted volume

      command = ["-config.file=/etc/loki/config.yml", "-config.expand-env=true"]

      portMappings = [
        { containerPort = 3100, protocol = "tcp", name = "http" },
        { containerPort = 9095, protocol = "tcp", name = "grpc" },
      ]

      mountPoints = [
        {
          sourceVolume  = "loki-data"
          containerPath = "/loki"
          readOnly      = false
        }
      ]

      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "S3_BUCKET",  value = var.s3_bucket  },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/ap-appe-otel/loki"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "loki"
          "awslogs-create-group"  = "true"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:3100/ready || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 5
        startPeriod = 90
      }
    }
  ])

  depends_on = [aws_cloudwatch_log_group.observability]

  tags = {
    Name = "ap-appe-otel-loki"
  }
}

resource "aws_ecs_service" "loki" {
  name            = "ap-appe-otel-loki"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.loki.arn
  desired_count   = 1
  launch_type     = "EC2"

  network_configuration {
    subnets          = [aws_subnet.otel_private.id]
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.services["loki"].arn
  }

  scheduling_strategy                = "REPLICA"
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  depends_on = [
    aws_ecs_cluster_capacity_providers.main,
    aws_cloudwatch_log_group.observability,
  ]

  tags = {
    Name = "ap-appe-otel-loki"
  }
}

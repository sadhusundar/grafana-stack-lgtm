###############################################################################
# service_prometheus.tf — Prometheus + Thanos Sidecar Task & Service
#
# Single task with two containers:
#   1. prometheus  — metrics collection + remote-write receiver
#   2. thanos-sidecar — uploads TSDB blocks to S3, exposes Store API on 10901
#
# CPU/Memory: task must exceed sum of containers to give ECS headroom.
#   prometheus=512cpu/1024mem + thanos-sidecar=256cpu/512mem = 768/1536
#   Task set to 1024/2048 for safe placement.
###############################################################################

resource "aws_ecs_task_definition" "prometheus" {
  family                   = "ap-appe-otel-prometheus"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  task_role_arn            = aws_iam_role.ecs_task.arn
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  cpu                      = "1024"
  memory                   = "2048"

  volume {
    name      = "prometheus-data"
    host_path = "/data/prometheus"
  }

  container_definitions = jsonencode([
    # ── Container 1: Prometheus ───────────────────────────────────────────────
    {
      name      = "prometheus"
      image     = "${var.ecr_base}/prometheus:${var.image_tag}"
      essential = true

      portMappings = [
        { containerPort = 9090, protocol = "tcp", name = "http" }
      ]

      mountPoints = [
        {
          sourceVolume  = "prometheus-data"
          containerPath = "/prometheus"
          readOnly      = false
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/ap-appe-otel/prometheus"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "prometheus"
          "awslogs-create-group"  = "true"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:9090/-/ready || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 5
        startPeriod = 60
      }
    },

    # ── Container 2: Thanos Sidecar ───────────────────────────────────────────
    {
      name      = "thanos-sidecar"
      image     = "${var.ecr_base}/thanos:${var.image_tag}"
      essential = false  # sidecar failure should not kill Prometheus

      command = [
        "sidecar",
        "--tsdb.path=/prometheus",
        "--prometheus.url=http://localhost:9090",
        "--grpc-address=0.0.0.0:10901",
        "--http-address=0.0.0.0:10902",
        "--objstore.config-file=/etc/thanos/bucket.yml",
      ]

      portMappings = [
        { containerPort = 10901, protocol = "tcp", name = "grpc" },
        { containerPort = 10902, protocol = "tcp", name = "http" },
      ]

      mountPoints = [
        {
          sourceVolume  = "prometheus-data"
          containerPath = "/prometheus"
          readOnly      = true
        }
      ]

      environment = [
        { name = "S3_BUCKET",  value = var.s3_bucket  },
        { name = "AWS_REGION", value = var.aws_region },
      ]

      dependsOn = [
        { containerName = "prometheus", condition = "HEALTHY" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/ap-appe-otel/thanos-sidecar"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "thanos-sidecar"
          "awslogs-create-group"  = "true"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:10902/-/ready || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 5
        startPeriod = 90
      }
    }
  ])

  depends_on = [aws_cloudwatch_log_group.observability]

  tags = {
    Name = "ap-appe-otel-prometheus"
  }
}

resource "aws_ecs_service" "prometheus" {
  name            = "ap-appe-otel-prometheus"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.prometheus.arn
  desired_count   = 1
  launch_type     = "EC2"

  network_configuration {
    subnets          = [aws_subnet.otel_private.id]
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.services["prometheus"].arn
  }

  scheduling_strategy                = "REPLICA"
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  depends_on = [
    aws_ecs_cluster_capacity_providers.main,
    aws_cloudwatch_log_group.observability,
  ]

  tags = {
    Name = "ap-appe-otel-prometheus"
  }
}

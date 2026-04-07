###############################################################################
# service_thanos_query.tf — Thanos Query Task & Service
#
# Thanos Query aggregates metrics from:
#   - thanos-sidecar (co-located in the Prometheus task): :10901 gRPC
# Exposes a Prometheus-compatible HTTP API on port 10902.
###############################################################################

resource "aws_ecs_task_definition" "thanos_query" {
  family                   = "ap-appe-otel-thanos-query"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  task_role_arn            = aws_iam_role.ecs_task.arn
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  cpu                      = "256"
  memory                   = "512"

  container_definitions = jsonencode([
    {
      name      = "thanos-query"
      image     = "${var.ecr_base}/thanos:${var.image_tag}"
      essential = true

      command = [
        "query",
        "--grpc-address=0.0.0.0:10901",
        "--http-address=0.0.0.0:10902",
        "--endpoint=prometheus.observability.local:10901",
        "--query.replica-label=replica",
        "--query.auto-downsampling",
      ]

      portMappings = [
        { containerPort = 10901, protocol = "tcp", name = "grpc" },
        { containerPort = 10902, protocol = "tcp", name = "http" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/ap-appe-otel/thanos-query"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "thanos-query"
          "awslogs-create-group"  = "true"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:10902/-/ready || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])

  depends_on = [aws_cloudwatch_log_group.observability]

  tags = {
    Name = "ap-appe-otel-thanos-query"
  }
}

resource "aws_ecs_service" "thanos_query" {
  name            = "ap-appe-otel-thanos-query"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.thanos_query.arn
  desired_count   = 1
  launch_type     = "EC2"

  network_configuration {
    subnets          = [aws_subnet.otel_private.id]
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.services["thanos-query"].arn
  }

  scheduling_strategy                = "REPLICA"
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  depends_on = [
    aws_ecs_service.prometheus,
    aws_ecs_cluster_capacity_providers.main,
    aws_cloudwatch_log_group.observability,
  ]

  tags = {
    Name = "ap-appe-otel-thanos-query"
  }
}

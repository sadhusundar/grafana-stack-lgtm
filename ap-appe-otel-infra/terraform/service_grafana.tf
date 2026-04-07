###############################################################################
# service_grafana.tf — Grafana Task & Service
#
# Datasources pre-provisioned via baked-in datasources.yml (Dockerfile).
# Host-mounted /data/grafana for SQLite DB persistence.
# Grafana UID=472 — user_data.sh pre-sets ownership of /data/grafana.
###############################################################################

resource "aws_ecs_task_definition" "grafana" {
  family                   = "ap-appe-otel-grafana"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  task_role_arn            = aws_iam_role.ecs_task.arn
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  cpu                      = "512"
  memory                   = "512"

  volume {
    name      = "grafana-data"
    host_path = "/data/grafana"
  }

  container_definitions = jsonencode([
    {
      name      = "grafana"
      image     = "${var.ecr_base}/grafana:${var.image_tag}"
      essential = true
      user      = "472"  # grafana UID — must match chown in user_data.sh

      portMappings = [
        { containerPort = 3000, protocol = "tcp", name = "http" }
      ]

      mountPoints = [
        {
          sourceVolume  = "grafana-data"
          containerPath = "/var/lib/grafana"
          readOnly      = false
        }
      ]

      environment = [
        { name = "GF_SECURITY_ADMIN_USER",                value = "admin"    },
        # ⚠ Change this password before deploying to production
        { name = "GF_SECURITY_ADMIN_PASSWORD",            value = "changeme" },
        { name = "GF_AUTH_ANONYMOUS_ENABLED",             value = "false"    },
        { name = "GF_SERVER_ROOT_URL",                    value = "http://grafana.observability.local:3000" },
        { name = "GF_FEATURE_TOGGLES_ENABLE",             value = "traceqlEditor" },
        # Suppress outbound internet calls (private subnet, no NAT)
        { name = "GF_UPDATES_CHECK_FOR_UPDATES",          value = "false"    },
        { name = "GF_ANALYTICS_CHECK_FOR_UPDATES",        value = "false"    },
        { name = "GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES", value = "false"    },
        { name = "GF_REPORTING_ENABLED",                  value = "false"    },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/ap-appe-otel/grafana"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "grafana"
          "awslogs-create-group"  = "true"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:3000/api/health || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])

  depends_on = [aws_cloudwatch_log_group.observability]

  tags = {
    Name = "ap-appe-otel-grafana"
  }
}

resource "aws_ecs_service" "grafana" {
  name            = "ap-appe-otel-grafana"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.grafana.arn
  desired_count   = 1
  launch_type     = "EC2"

  network_configuration {
    subnets          = [aws_subnet.otel_private.id]
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.services["grafana"].arn
  }

  scheduling_strategy                = "REPLICA"
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  depends_on = [
    aws_ecs_service.prometheus,
    aws_ecs_service.loki,
    aws_ecs_service.tempo,
    aws_ecs_service.thanos_query,
    aws_ecs_cluster_capacity_providers.main,
    aws_cloudwatch_log_group.observability,
  ]

  tags = {
    Name = "ap-appe-otel-grafana"
  }
}

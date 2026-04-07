###############################################################################
# cloudwatch.tf — CloudWatch Log Groups
# Pre-created so ECS tasks never fail due to missing log groups.
# Note: alloy and node-exporter log groups removed per requirements.
###############################################################################

locals {
  log_groups = toset([
    "/ecs/ap-appe-otel/prometheus",
    "/ecs/ap-appe-otel/thanos-sidecar",
    "/ecs/ap-appe-otel/thanos-query",
    "/ecs/ap-appe-otel/loki",
    "/ecs/ap-appe-otel/tempo",
    "/ecs/ap-appe-otel/grafana",
  ])
}

resource "aws_cloudwatch_log_group" "observability" {
  for_each          = local.log_groups
  name              = each.value
  retention_in_days = 30

  tags = {
    Name = each.value
  }

  lifecycle {
    # Ignore changes if awslogs-create-group already created the group
    ignore_changes = all
  }
}

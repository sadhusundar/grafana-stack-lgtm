###############################################################################
# service_discovery.tf — AWS Cloud Map (Route53 private DNS)
#
# Each awsvpc task gets its own ENI/IP. Cloud Map registers the IP under
# observability.local so containers resolve each other by DNS name.
# Removed: alloy, node-exporter
###############################################################################

resource "aws_service_discovery_private_dns_namespace" "observability" {
  name        = "observability.local"
  description = "Private DNS namespace for ap-appe-otel ECS services"
  vpc         = var.vpc_id

  tags = {
    Name = "ap-appe-otel-observability-local"
  }
}

locals {
  # service name → primary port (documentation only — DNS uses A records)
  discovery_services = {
    "prometheus"   = 9090
    "loki"         = 3100
    "tempo"        = 3200
    "thanos-query" = 10902
    "grafana"      = 3000
  }
}

resource "aws_service_discovery_service" "services" {
  for_each = local.discovery_services

  name = each.key

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.observability.id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = {
    Name = "ap-appe-otel-sd-${each.key}"
  }
}

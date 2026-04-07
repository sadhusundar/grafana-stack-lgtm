###############################################################################
# ecr.tf — ECR Repositories
# Excluded: alloy, node-exporter (removed per requirements)
###############################################################################

locals {
  ecr_repos = toset([
    "ap-appe-otel/prometheus",
    "ap-appe-otel/loki",
    "ap-appe-otel/tempo",
    "ap-appe-otel/thanos",
    "ap-appe-otel/grafana",
  ])
}

resource "aws_ecr_repository" "observability" {
  for_each             = local.ecr_repos
  name                 = each.value
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = each.value
  }
}

# Lifecycle policy: keep last 5 images per repository
resource "aws_ecr_lifecycle_policy" "observability" {
  for_each   = aws_ecr_repository.observability
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Retain last 5 images; expire older ones"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

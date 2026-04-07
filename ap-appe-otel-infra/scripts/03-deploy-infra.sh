#!/usr/bin/env bash
###############################################################################
# 03-deploy-infra.sh — Deploy the full AWS infrastructure via Terraform
#
# Order of operations (Terraform handles dependency graph internally,
# but we use targeted applies to ensure safe ordering):
#
#   Phase 1: Foundation  — VPC endpoints, IAM, S3, CloudWatch, Service Discovery
#   Phase 2: Cluster     — ECS cluster, ASG, Launch Template, Capacity Provider
#   Phase 3: Services    — ECS Task Definitions + Services (dependency order)
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"
REGION="us-east-1"
CLUSTER="ap-appe-ecs-otel"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
info()  { echo -e "${CYAN}[→]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
fail()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
header(){ echo ""; echo -e "${CYAN}══════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}══════════════════════════════════════${NC}"; }

cd "$TF_DIR"

# ── Pre-flight: images must exist in ECR ─────────────────────────────────────
header "Pre-flight: Verify ECR Images"
ACCOUNT_ID="584554046133"
ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/ap-appe-otel"
MISSING=0
for svc in prometheus loki tempo thanos grafana; do
  COUNT=$(aws ecr describe-images \
    --repository-name "ap-appe-otel/${svc}" \
    --region "$REGION" \
    --query 'length(imageDetails)' \
    --output text 2>/dev/null || echo "0")
  if [[ "$COUNT" -gt 0 ]]; then
    ok "ECR ap-appe-otel/${svc}: $COUNT image(s)"
  else
    echo -e "${RED}[✗]${NC} ECR ap-appe-otel/${svc}: NO IMAGES — run scripts/02-build-push.sh first"
    MISSING=$((MISSING + 1))
  fi
done
[[ "$MISSING" -gt 0 ]] && fail "$MISSING ECR repos have no images. Push images first."

# ── Phase 1: Foundation ───────────────────────────────────────────────────────
header "Phase 1: Foundation Resources"
warn "This creates: subnet, security groups, VPC endpoints, IAM roles, S3, CloudWatch, Service Discovery"
read -rp "Proceed with Phase 1? [y/N]: " p1
[[ "${p1,,}" != "y" ]] && echo "Aborted." && exit 0

info "Applying foundation resources..."
terraform apply \
  -target=aws_subnet.otel_private \
  -target=aws_route_table.otel_private \
  -target=aws_route_table_association.otel_private \
  -target=aws_security_group.ecs_instances \
  -target=aws_security_group.ecs_tasks \
  -target=aws_vpc_endpoint.ecr_api \
  -target=aws_vpc_endpoint.ecr_dkr \
  -target=aws_vpc_endpoint.cloudwatch_logs \
  -target=aws_vpc_endpoint.ssm \
  -target=aws_vpc_endpoint.ssm_messages \
  -target=aws_vpc_endpoint.ec2_messages \
  -target=aws_iam_role.ecs_execution \
  -target=aws_iam_role.ecs_task \
  -target=aws_iam_role.ec2_instance \
  -target=aws_iam_role_policy_attachment.execution_managed \
  -target=aws_iam_role_policy.execution_logs \
  -target=aws_iam_role_policy.task_s3 \
  -target=aws_iam_role_policy_attachment.ec2_ecs_policy \
  -target=aws_iam_role_policy_attachment.ec2_ssm_policy \
  -target=aws_iam_role_policy_attachment.ec2_cloudwatch_policy \
  -target=aws_iam_instance_profile.ec2 \
  -target=aws_s3_bucket.observability \
  -target=aws_s3_bucket_public_access_block.observability \
  -target=aws_s3_bucket_versioning.observability \
  -target=aws_s3_bucket_server_side_encryption_configuration.observability \
  -target=aws_s3_bucket_lifecycle_configuration.observability \
  -target=aws_s3_bucket_policy.observability \
  -target=aws_cloudwatch_log_group.observability \
  -target=aws_service_discovery_private_dns_namespace.observability \
  -target=aws_service_discovery_service.services \
  -auto-approve

ok "Phase 1 complete"

# S3 Gateway Endpoint (separate — depends on s3 bucket and route table)
info "Applying S3 gateway endpoint..."
terraform apply \
  -target=aws_vpc_endpoint.s3 \
  -auto-approve 2>/dev/null || \
  warn "S3 endpoint skipped (may already exist — check vpc_endpoints.tf data source)"

# ── Phase 2: ECS Cluster + ASG ────────────────────────────────────────────────
header "Phase 2: ECS Cluster, ASG & Capacity Provider"
warn "This launches 2 × t3.xlarge EC2 instances and creates the ECS cluster"
read -rp "Proceed with Phase 2? [y/N]: " p2
[[ "${p2,,}" != "y" ]] && echo "Aborted." && exit 0

terraform apply \
  -target=aws_ecs_cluster.main \
  -target=aws_launch_template.ecs \
  -target=aws_autoscaling_group.ecs \
  -target=aws_ecs_capacity_provider.ec2 \
  -target=aws_ecs_cluster_capacity_providers.main \
  -auto-approve

ok "ECS cluster and ASG created"

# Wait for instances to register
info "Waiting for EC2 instances to register with ECS cluster (up to 5 minutes)..."
for i in $(seq 1 30); do
  REGISTERED=$(aws ecs describe-clusters \
    --clusters "$CLUSTER" \
    --region "$REGION" \
    --query 'clusters[0].registeredContainerInstancesCount' \
    --output text 2>/dev/null || echo "0")
  if [[ "$REGISTERED" -ge 2 ]]; then
    ok "2 instances registered with cluster"
    break
  fi
  echo "  Waiting... ($i/30) — registered: ${REGISTERED}/2"
  sleep 10
done

REGISTERED=$(aws ecs describe-clusters \
  --clusters "$CLUSTER" --region "$REGION" \
  --query 'clusters[0].registeredContainerInstancesCount' --output text)
[[ "$REGISTERED" -lt 2 ]] && warn "Only $REGISTERED/2 instances registered — services may not place yet"

# ── Phase 3: ECS Services ─────────────────────────────────────────────────────
header "Phase 3: ECS Task Definitions & Services"
warn "Deploying services in dependency order: prometheus → loki → tempo → thanos-query → grafana"
read -rp "Proceed with Phase 3? [y/N]: " p3
[[ "${p3,,}" != "y" ]] && echo "Aborted." && exit 0

# Prometheus + Thanos Sidecar (foundation of metrics stack)
info "Deploying Prometheus + Thanos Sidecar..."
terraform apply \
  -target=aws_ecs_task_definition.prometheus \
  -target=aws_ecs_service.prometheus \
  -auto-approve
ok "Prometheus service deployed"
sleep 15

# Loki (independent)
info "Deploying Loki..."
terraform apply \
  -target=aws_ecs_task_definition.loki \
  -target=aws_ecs_service.loki \
  -auto-approve
ok "Loki service deployed"

# Tempo (independent)
info "Deploying Tempo..."
terraform apply \
  -target=aws_ecs_task_definition.tempo \
  -target=aws_ecs_service.tempo \
  -auto-approve
ok "Tempo service deployed"

# Thanos Query (depends on prometheus sidecar being healthy)
info "Deploying Thanos Query..."
terraform apply \
  -target=aws_ecs_task_definition.thanos_query \
  -target=aws_ecs_service.thanos_query \
  -auto-approve
ok "Thanos Query service deployed"

# Grafana (depends on all backends)
info "Deploying Grafana..."
terraform apply \
  -target=aws_ecs_task_definition.grafana \
  -target=aws_ecs_service.grafana \
  -auto-approve
ok "Grafana service deployed"

# ── Final full apply (catch any drift) ───────────────────────────────────────
header "Final: Full Apply (cleanup)"
info "Running full terraform apply to reconcile any remaining resources..."
terraform apply -auto-approve

# ── Summary ──────────────────────────────────────────────────────────────────
header "Deployment Complete"
ok "Infrastructure deployed successfully"
echo ""
echo "Useful outputs:"
terraform output -json | jq -r 'to_entries[] | "  \(.key): \(.value.value)"' 2>/dev/null || terraform output
echo ""
echo "Next: run scripts/04-validate.sh to verify all services are healthy"

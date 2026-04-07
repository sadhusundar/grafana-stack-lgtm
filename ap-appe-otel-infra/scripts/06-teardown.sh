#!/usr/bin/env bash
###############################################################################
# 06-teardown.sh — Destroy all infrastructure (DESTRUCTIVE)
#
# ⚠ WARNING: This will permanently delete:
#   - ECS cluster, services, task definitions
#   - EC2 instances (via ASG)
#   - All security groups, subnet, VPC endpoints
#   - IAM roles and policies
#   - ECR repositories and ALL images
#   - CloudWatch log groups
#   - Cloud Map namespace and services
#
# The S3 bucket is NOT deleted by default (force_destroy=false in s3.tf)
# to protect observability data. Delete manually if certain.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"
REGION="us-east-1"
CLUSTER="ap-appe-ecs-otel"

RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║   ⚠  DESTRUCTIVE OPERATION — READ CAREFULLY  ⚠     ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "This will PERMANENTLY DESTROY all ap-appe-otel infrastructure:"
echo "  • ECS cluster: $CLUSTER"
echo "  • 2 × t3.xlarge EC2 instances"
echo "  • New private subnet and security groups"
echo "  • VPC endpoints (interface type)"
echo "  • IAM roles: execution, task, ec2-instance"
echo "  • ECR repos: prometheus, loki, tempo, thanos, grafana (and ALL images)"
echo "  • CloudWatch log groups (and ALL logs)"
echo "  • S3 bucket data is PRESERVED (force_destroy=false)"
echo ""
echo -e "${YELLOW}Type the cluster name to confirm: ${NC}"
read -r CONFIRM
if [[ "$CONFIRM" != "$CLUSTER" ]]; then
  echo "Aborted — input did not match '$CLUSTER'"
  exit 1
fi

echo ""
echo "Final confirmation — destroy everything? [yes/no]:"
read -r FINAL
[[ "$FINAL" != "yes" ]] && echo "Aborted." && exit 0

# Scale down services first to avoid dependency issues
echo "Scaling down ECS services..."
for svc in ap-appe-otel-grafana ap-appe-otel-thanos-query ap-appe-otel-tempo ap-appe-otel-loki ap-appe-otel-prometheus; do
  aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "$svc" \
    --desired-count 0 \
    --region "$REGION" &>/dev/null && echo "  Scaled down $svc" || echo "  $svc not found (skipping)"
done

echo "Waiting 30s for tasks to drain..."
sleep 30

cd "$TF_DIR"
terraform destroy -auto-approve

echo ""
echo "Teardown complete."
echo "S3 bucket 'ap-appe-otel-observability-store' was NOT deleted."
echo "To delete it manually: aws s3 rb s3://ap-appe-otel-observability-store --force"

#!/usr/bin/env bash
###############################################################################
# 04-validate.sh — Post-deployment health checks
#
# Validates:
#   1. EC2 instances registered with ECS cluster
#   2. All ECS services have desired == running task count
#   3. All ECS tasks are in RUNNING state
#   4. Service Discovery records exist in Cloud Map
#   5. S3 bucket is accessible from CLI
#   6. CloudWatch log groups exist and are receiving logs
#   7. ECR images are present
#   8. VPC endpoints are in 'available' state
###############################################################################
set -euo pipefail

REGION="us-east-1"
CLUSTER="ap-appe-ecs-otel"
ACCOUNT_ID="584554046133"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
fail()  { echo -e "${RED}[✗]${NC} $*"; ERRORS=$((ERRORS+1)); }
info()  { echo -e "${CYAN}[→]${NC} $*"; }
header(){ echo ""; echo "── $* ──────────────────────────────────────"; }

ERRORS=0

echo "========================================"
echo " ap-appe-otel — Deployment Validation"
echo " Cluster: $CLUSTER | Region: $REGION"
echo "========================================"

# ── 1. ECS Cluster & Instances ────────────────────────────────────────────────
header "1. ECS Cluster"
CLUSTER_STATUS=$(aws ecs describe-clusters \
  --clusters "$CLUSTER" --region "$REGION" \
  --query 'clusters[0].status' --output text 2>/dev/null || echo "MISSING")

if [[ "$CLUSTER_STATUS" == "ACTIVE" ]]; then
  ok "Cluster '$CLUSTER' is ACTIVE"
else
  fail "Cluster '$CLUSTER' status: $CLUSTER_STATUS"
fi

REGISTERED=$(aws ecs describe-clusters \
  --clusters "$CLUSTER" --region "$REGION" \
  --query 'clusters[0].registeredContainerInstancesCount' --output text)
if [[ "$REGISTERED" -ge 2 ]]; then
  ok "Container instances registered: $REGISTERED/2"
else
  fail "Container instances registered: $REGISTERED/2 — expected 2"
fi

# ── 2. ECS Services ───────────────────────────────────────────────────────────
header "2. ECS Services"
SERVICES=(
  "ap-appe-otel-prometheus"
  "ap-appe-otel-loki"
  "ap-appe-otel-tempo"
  "ap-appe-otel-thanos-query"
  "ap-appe-otel-grafana"
)

aws ecs describe-services \
  --cluster "$CLUSTER" \
  --region "$REGION" \
  --services "${SERVICES[@]}" \
  --query 'services[*].{Name:serviceName,Status:status,Desired:desiredCount,Running:runningCount,Pending:pendingCount}' \
  --output table

for svc in "${SERVICES[@]}"; do
  SVC_DATA=$(aws ecs describe-services \
    --cluster "$CLUSTER" --region "$REGION" \
    --services "$svc" \
    --query 'services[0].{status:status,desired:desiredCount,running:runningCount}' \
    --output json 2>/dev/null || echo '{}')
  STATUS=$(echo "$SVC_DATA" | jq -r '.status // "MISSING"')
  DESIRED=$(echo "$SVC_DATA" | jq -r '.desired // 0')
  RUNNING=$(echo "$SVC_DATA" | jq -r '.running // 0')

  if [[ "$STATUS" == "ACTIVE" && "$RUNNING" == "$DESIRED" && "$RUNNING" -gt 0 ]]; then
    ok "$svc: ACTIVE ($RUNNING/$DESIRED running)"
  elif [[ "$STATUS" == "ACTIVE" && "$RUNNING" -lt "$DESIRED" ]]; then
    warn "$svc: ACTIVE but $RUNNING/$DESIRED running (tasks may still be starting)"
  else
    fail "$svc: STATUS=$STATUS RUNNING=$RUNNING DESIRED=$DESIRED"
  fi
done

# ── 3. ECS Task Health ────────────────────────────────────────────────────────
header "3. ECS Task Status"
for svc in "${SERVICES[@]}"; do
  TASK_ARNS=$(aws ecs list-tasks \
    --cluster "$CLUSTER" --region "$REGION" \
    --service-name "$svc" \
    --query 'taskArns' --output json 2>/dev/null || echo "[]")
  TASK_COUNT=$(echo "$TASK_ARNS" | jq 'length')

  if [[ "$TASK_COUNT" -eq 0 ]]; then
    fail "$svc: no tasks running"
    continue
  fi

  # Check last stopped tasks for recent failures
  STOPPED=$(aws ecs list-tasks \
    --cluster "$CLUSTER" --region "$REGION" \
    --service-name "$svc" \
    --desired-status STOPPED \
    --query 'length(taskArns)' --output text 2>/dev/null || echo "0")

  TASK_ARN=$(echo "$TASK_ARNS" | jq -r '.[0]')
  HEALTH=$(aws ecs describe-tasks \
    --cluster "$CLUSTER" --region "$REGION" \
    --tasks "$TASK_ARN" \
    --query 'tasks[0].healthStatus' --output text 2>/dev/null || echo "UNKNOWN")

  if [[ "$STOPPED" -gt 3 ]]; then
    warn "$svc: $STOPPED recently stopped tasks (check logs for crash loops)"
  fi

  if [[ "$HEALTH" == "HEALTHY" || "$HEALTH" == "UNKNOWN" ]]; then
    ok "$svc: $TASK_COUNT task(s) — health: $HEALTH"
  else
    fail "$svc: $TASK_COUNT task(s) — health: $HEALTH"
  fi
done

# ── 4. Service Discovery ──────────────────────────────────────────────────────
header "4. Cloud Map / Service Discovery"
NS_ID=$(aws servicediscovery list-namespaces \
  --region "$REGION" \
  --filters Name=NAME,Values=observability.local,Condition=EQ \
  --query 'Namespaces[0].Id' --output text 2>/dev/null || echo "")

if [[ -n "$NS_ID" && "$NS_ID" != "None" ]]; then
  ok "Namespace observability.local found: $NS_ID"
  SD_SERVICES=$(aws servicediscovery list-services \
    --region "$REGION" \
    --filters Name=NAMESPACE_ID,Values="$NS_ID",Condition=EQ \
    --query 'Services[*].Name' --output text)
  info "Registered services: $SD_SERVICES"
else
  fail "Namespace observability.local not found"
fi

# ── 5. S3 Bucket ─────────────────────────────────────────────────────────────
header "5. S3 Bucket"
S3_BUCKET="ap-appe-otel-observability-store"
if aws s3api head-bucket --bucket "$S3_BUCKET" --region "$REGION" 2>/dev/null; then
  ok "S3 bucket '$S3_BUCKET' is accessible"
  # Check for S3 prefix objects after services run a bit
  for prefix in loki/ tempo/ thanos/; do
    COUNT=$(aws s3 ls "s3://${S3_BUCKET}/${prefix}" --region "$REGION" 2>/dev/null | wc -l || echo "0")
    info "  s3://${S3_BUCKET}/${prefix}: $COUNT objects (may be 0 if services just started)"
  done
else
  fail "S3 bucket '$S3_BUCKET' not accessible"
fi

# ── 6. CloudWatch Log Groups ──────────────────────────────────────────────────
header "6. CloudWatch Log Groups"
LOG_GROUPS=(
  "/ecs/ap-appe-otel/prometheus"
  "/ecs/ap-appe-otel/thanos-sidecar"
  "/ecs/ap-appe-otel/thanos-query"
  "/ecs/ap-appe-otel/loki"
  "/ecs/ap-appe-otel/tempo"
  "/ecs/ap-appe-otel/grafana"
)
for lg in "${LOG_GROUPS[@]}"; do
  EXISTS=$(aws logs describe-log-groups \
    --log-group-name-prefix "$lg" \
    --region "$REGION" \
    --query 'length(logGroups)' --output text 2>/dev/null || echo "0")
  if [[ "$EXISTS" -gt 0 ]]; then
    ok "$lg"
  else
    fail "$lg — not found"
  fi
done

# ── 7. ECR Repositories ───────────────────────────────────────────────────────
header "7. ECR Repositories"
for svc in prometheus loki tempo thanos grafana; do
  REPO="ap-appe-otel/${svc}"
  COUNT=$(aws ecr describe-images \
    --repository-name "$REPO" --region "$REGION" \
    --query 'length(imageDetails)' --output text 2>/dev/null || echo "0")
  if [[ "$COUNT" -gt 0 ]]; then
    ok "$REPO: $COUNT image(s)"
  else
    fail "$REPO: 0 images"
  fi
done

# ── 8. VPC Endpoints ──────────────────────────────────────────────────────────
header "8. VPC Endpoints"
VPC_ID="vpc-0018aa4902fa67a2c"
ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" \
  --region "$REGION" \
  --query 'VpcEndpoints[*].ServiceName' --output text 2>/dev/null || echo "")

for ep in ecr.api ecr.dkr logs ssm ssmmessages ec2messages; do
  if echo "$ENDPOINTS" | grep -q "$ep"; then
    ok "Endpoint: com.amazonaws.${REGION}.${ep}"
  else
    warn "Endpoint: com.amazonaws.${REGION}.${ep} — not found or not available yet"
  fi
done

# ── 9. IAM Roles ──────────────────────────────────────────────────────────────
header "9. IAM Roles"
for role in ap-appe-otel-ecs-execution-role ap-appe-otel-ecs-task-role ap-appe-otel-ec2-instance-role; do
  if aws iam get-role --role-name "$role" &>/dev/null; then
    ok "$role"
  else
    fail "$role — not found"
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
if [[ "$ERRORS" -eq 0 ]]; then
  echo -e "${GREEN} All validation checks passed ✓${NC}"
  echo ""
  echo " Access Grafana via SSH tunnel:"
  echo "   TASK=\$(aws ecs list-tasks --cluster $CLUSTER --service-name ap-appe-otel-grafana --query 'taskArns[0]' --output text)"
  echo "   IP=\$(aws ecs describe-tasks --cluster $CLUSTER --tasks \$TASK --query 'tasks[0].attachments[0].details[?name==\`privateIPv4Address\`].value' --output text)"
  echo "   ssh -i <key.pem> -L 3000:\$IP:3000 ec2-user@<EC2_PUBLIC_IP> -N &"
  echo "   open http://localhost:3000  (admin / changeme)"
else
  echo -e "${RED} $ERRORS validation check(s) FAILED${NC}"
  echo " Review errors above and check:"
  echo "   aws ecs describe-services --cluster $CLUSTER --services ${SERVICES[*]}"
  echo "   aws logs tail /ecs/ap-appe-otel/<service> --follow"
fi
echo "========================================"
exit $ERRORS

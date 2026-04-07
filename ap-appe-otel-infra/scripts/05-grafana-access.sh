#!/usr/bin/env bash
###############################################################################
# 05-grafana-access.sh — Open SSH tunnel to Grafana
#
# Usage: ./05-grafana-access.sh <path-to-key.pem> [EC2_PUBLIC_IP]
#
# If EC2_PUBLIC_IP is omitted, the script will try to find an instance
# with SSM Session Manager (no public IP required if using SSM).
###############################################################################
set -euo pipefail

REGION="us-east-1"
CLUSTER="ap-appe-ecs-otel"
KEY_FILE="${1:-}"
EC2_IP="${2:-}"
LOCAL_PORT=3000

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${CYAN}[→]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
fail() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ── Get Grafana task private IP ───────────────────────────────────────────────
info "Finding Grafana task..."
TASK_ARN=$(aws ecs list-tasks \
  --cluster "$CLUSTER" \
  --region "$REGION" \
  --service-name "ap-appe-otel-grafana" \
  --query 'taskArns[0]' --output text 2>/dev/null || echo "")

[[ -z "$TASK_ARN" || "$TASK_ARN" == "None" ]] && \
  fail "No Grafana task found. Is ap-appe-otel-grafana service running?"

ok "Found task: $TASK_ARN"

GRAFANA_IP=$(aws ecs describe-tasks \
  --cluster "$CLUSTER" \
  --region "$REGION" \
  --tasks "$TASK_ARN" \
  --query 'tasks[0].attachments[0].details[?name==`privateIPv4Address`].value' \
  --output text)

[[ -z "$GRAFANA_IP" || "$GRAFANA_IP" == "None" ]] && \
  fail "Could not determine Grafana task IP. Task may still be starting."

ok "Grafana private IP: $GRAFANA_IP"

# ── Method 1: Direct SSH tunnel (if EC2 has public IP) ───────────────────────
if [[ -n "$KEY_FILE" && -n "$EC2_IP" ]]; then
  [[ ! -f "$KEY_FILE" ]] && fail "Key file not found: $KEY_FILE"
  chmod 400 "$KEY_FILE"

  info "Opening SSH tunnel: localhost:${LOCAL_PORT} → $GRAFANA_IP:3000"
  info "Press Ctrl+C to close the tunnel"
  echo ""
  echo "  Open browser: http://localhost:${LOCAL_PORT}"
  echo "  Credentials:  admin / changeme"
  echo ""
  ssh -i "$KEY_FILE" \
      -L "${LOCAL_PORT}:${GRAFANA_IP}:3000" \
      -N \
      -o StrictHostKeyChecking=no \
      -o ServerAliveInterval=60 \
      "ec2-user@${EC2_IP}"

# ── Method 2: SSM Port Forwarding (no public IP required) ────────────────────
else
  info "No EC2 IP provided — using SSM Session Manager port forwarding"

  # Find an ECS container instance
  CONTAINER_INSTANCES=$(aws ecs list-container-instances \
    --cluster "$CLUSTER" --region "$REGION" \
    --query 'containerInstanceArns' --output json)
  FIRST_CI=$(echo "$CONTAINER_INSTANCES" | jq -r '.[0]')
  [[ -z "$FIRST_CI" || "$FIRST_CI" == "null" ]] && fail "No container instances found"

  EC2_INSTANCE_ID=$(aws ecs describe-container-instances \
    --cluster "$CLUSTER" --region "$REGION" \
    --container-instances "$FIRST_CI" \
    --query 'containerInstances[0].ec2InstanceId' --output text)

  ok "Using EC2 instance: $EC2_INSTANCE_ID"
  info "Opening SSM port-forward: localhost:${LOCAL_PORT} → $GRAFANA_IP:3000"
  echo ""
  echo "  Open browser: http://localhost:${LOCAL_PORT}"
  echo "  Credentials:  admin / changeme"
  echo "  Press Ctrl+C to close"
  echo ""

  aws ssm start-session \
    --target "$EC2_INSTANCE_ID" \
    --region "$REGION" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "{\"host\":[\"$GRAFANA_IP\"],\"portNumber\":[\"3000\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}"
fi

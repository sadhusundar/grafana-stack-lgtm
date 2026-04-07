#!/usr/bin/env bash
###############################################################################
# 02-build-push.sh — Build Docker images and push to ECR
#
# Services built (Alloy and Node Exporter EXCLUDED per requirements):
#   - prometheus, loki, tempo, thanos, grafana
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$SCRIPT_DIR/../docker"
REGION="us-east-1"
ACCOUNT_ID="584554046133"
ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/ap-appe-otel"
IMAGE_TAG="${IMAGE_TAG:-latest}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${CYAN}[→]${NC} $*"; }
fail() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

echo "========================================"
echo " Step 2: Build & Push Docker Images"
echo " Tag: $IMAGE_TAG"
echo "========================================"

# ── ECR Authentication ────────────────────────────────────────────────────────
info "Authenticating with ECR..."
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
ok "ECR authentication successful"

# ── Services to build ─────────────────────────────────────────────────────────
# Note: alloy and node-exporter intentionally excluded
declare -A SERVICES=(
  ["prometheus"]="$DOCKER_DIR/prometheus"
  ["loki"]="$DOCKER_DIR/loki"
  ["tempo"]="$DOCKER_DIR/tempo"
  ["thanos"]="$DOCKER_DIR/thanos"
  ["grafana"]="$DOCKER_DIR/grafana"
)

BUILD_ERRORS=0
for service in "${!SERVICES[@]}"; do
  context="${SERVICES[$service]}"
  repo="${ECR_BASE}/${service}"
  local_tag="ap-appe-otel-${service}:${IMAGE_TAG}"
  remote_tag="${repo}:${IMAGE_TAG}"

  echo ""
  info "Building: $service"
  info "  Context : $context"
  info "  Remote  : $remote_tag"

  if ! docker build \
    --platform linux/amd64 \
    -t "$local_tag" \
    -t "$remote_tag" \
    "$context"; then
    echo -e "${RED}[✗] Build failed for $service${NC}"
    BUILD_ERRORS=$((BUILD_ERRORS + 1))
    continue
  fi
  ok "Built: $service"

  info "Pushing $remote_tag..."
  if ! docker push "$remote_tag"; then
    echo -e "${RED}[✗] Push failed for $service${NC}"
    BUILD_ERRORS=$((BUILD_ERRORS + 1))
    continue
  fi
  ok "Pushed: $remote_tag"
done

echo ""
if [[ "$BUILD_ERRORS" -gt 0 ]]; then
  fail "$BUILD_ERRORS service(s) failed to build/push. Fix errors above and re-run."
fi

ok "All images built and pushed successfully"
echo ""
echo "Images in ECR:"
for service in "${!SERVICES[@]}"; do
  echo "  ${ECR_BASE}/${service}:${IMAGE_TAG}"
done
echo ""
echo "Next: run scripts/03-deploy-infra.sh to deploy the full infrastructure"

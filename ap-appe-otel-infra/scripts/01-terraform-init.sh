#!/usr/bin/env bash
###############################################################################
# 01-terraform-init.sh — Initialize Terraform and create ECR repositories
#
# What this does:
#   1. Runs terraform init
#   2. Runs terraform plan (review only)
#   3. Creates ONLY the ECR repositories (targeted apply) so images can be
#      pushed before the full cluster is deployed.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"
REGION="us-east-1"
ACCOUNT_ID="584554046133"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${CYAN}[→]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

echo "========================================"
echo " Step 1: Terraform Init + ECR Setup"
echo "========================================"

# ── Check terraform.tfvars is configured ─────────────────────────────────────
if grep -q "REPLACE_WITH_YOUR_KEY_PAIR_NAME" "$TF_DIR/terraform.tfvars"; then
  echo -e "${RED}[✗]${NC} terraform.tfvars still has placeholder 'REPLACE_WITH_YOUR_KEY_PAIR_NAME'"
  echo "    Edit terraform/terraform.tfvars and set key_name to your EC2 key pair."
  exit 1
fi
ok "terraform.tfvars looks configured"

# ── Terraform Init ────────────────────────────────────────────────────────────
info "Running terraform init..."
cd "$TF_DIR"
terraform init -upgrade

# ── Terraform Validate ────────────────────────────────────────────────────────
info "Validating configuration..."
terraform validate && ok "Configuration is valid"

# ── Terraform Plan ────────────────────────────────────────────────────────────
info "Generating plan (review carefully)..."
terraform plan -out=tfplan.binary
terraform show -no-color tfplan.binary > tfplan.txt
echo ""
warn "Plan written to terraform/tfplan.txt — review before proceeding"
echo ""

# ── Create ECR Repositories First ─────────────────────────────────────────────
read -rp "Create ECR repositories now? [y/N]: " confirm
if [[ "${confirm,,}" != "y" ]]; then
  echo "Aborted. Run again when ready."
  exit 0
fi

info "Creating ECR repositories..."
terraform apply -target=aws_ecr_repository.observability \
                -target=aws_ecr_lifecycle_policy.observability \
                -auto-approve

ok "ECR repositories created"
echo ""
echo "ECR base URI: ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/ap-appe-otel"
echo ""
echo "Next: run scripts/02-build-push.sh to build and push Docker images"

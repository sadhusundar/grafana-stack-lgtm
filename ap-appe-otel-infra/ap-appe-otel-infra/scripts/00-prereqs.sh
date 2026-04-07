#!/usr/bin/env bash
###############################################################################
# 00-prereqs.sh — Verify all required tools and AWS access exist
# Run this FIRST before any other script.
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
fail() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

echo "========================================"
echo " ap-appe-otel — Prerequisites Check"
echo "========================================"

# ── CLI Tools ─────────────────────────────────────────────────────────────────
for tool in aws terraform docker jq; do
  if command -v "$tool" &>/dev/null; then
    ok "$tool found: $(command -v $tool)"
  else
    fail "$tool not found — install it before continuing"
  fi
done

# Terraform version
TF_VER=$(terraform version -json | jq -r '.terraform_version')
TF_MAJOR=$(echo "$TF_VER" | cut -d. -f1)
TF_MINOR=$(echo "$TF_VER" | cut -d. -f2)
if [[ "$TF_MAJOR" -ge 1 && "$TF_MINOR" -ge 5 ]]; then
  ok "Terraform $TF_VER >= 1.5"
else
  fail "Terraform $TF_VER < 1.5 — upgrade required"
fi

# ── AWS Credentials ───────────────────────────────────────────────────────────
echo ""
echo "── AWS Identity ────────────────────────────────────"
CALLER=$(aws sts get-caller-identity 2>/dev/null) || fail "AWS credentials not configured (run 'aws configure' or set AWS_* env vars)"
ACCT=$(echo "$CALLER" | jq -r '.Account')
ARN=$(echo "$CALLER" | jq -r '.Arn')
ok "Account : $ACCT"
ok "Identity: $ARN"

if [[ "$ACCT" != "584554046133" ]]; then
  warn "Account $ACCT does not match expected 584554046133 — are you in the right account?"
fi

# ── AWS Region ────────────────────────────────────────────────────────────────
REGION=$(aws configure get region 2>/dev/null || echo "${AWS_DEFAULT_REGION:-}")
if [[ "$REGION" == "us-east-1" ]]; then
  ok "Region: us-east-1"
else
  warn "Active region is '${REGION:-unset}' — scripts expect us-east-1"
  warn "Set with: export AWS_DEFAULT_REGION=us-east-1"
fi

# ── VPC Exists ────────────────────────────────────────────────────────────────
echo ""
echo "── VPC Check ────────────────────────────────────────"
VPC_STATE=$(aws ec2 describe-vpcs \
  --vpc-ids vpc-0018aa4902fa67a2c \
  --region us-east-1 \
  --query 'Vpcs[0].State' --output text 2>/dev/null) || fail "VPC vpc-0018aa4902fa67a2c not found"
ok "VPC vpc-0018aa4902fa67a2c is $VPC_STATE"

# ── Subnet CIDR Conflict Check ────────────────────────────────────────────────
echo ""
echo "── Subnet CIDR Availability ─────────────────────────"
EXISTING_CIDRS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=vpc-0018aa4902fa67a2c" \
  --region us-east-1 \
  --query 'Subnets[*].CidrBlock' --output text)
echo "Existing subnet CIDRs in VPC:"
echo "$EXISTING_CIDRS"
if echo "$EXISTING_CIDRS" | grep -q "10.0.64.0/24"; then
  fail "CIDR 10.0.64.0/24 is already in use — update subnet_cidr in terraform.tfvars"
else
  ok "CIDR 10.0.64.0/24 is available"
fi

# ── Key Pair Check ────────────────────────────────────────────────────────────
echo ""
echo "── Key Pairs in us-east-1 ───────────────────────────"
aws ec2 describe-key-pairs --region us-east-1 \
  --query 'KeyPairs[*].KeyName' --output table
warn "Make sure your key_name in terraform.tfvars matches one of the above"

# ── Docker Daemon ─────────────────────────────────────────────────────────────
echo ""
echo "── Docker ───────────────────────────────────────────"
docker info &>/dev/null && ok "Docker daemon is running" || fail "Docker daemon is not running"

echo ""
echo "========================================"
echo " All prerequisites satisfied ✓"
echo " Next: run scripts/01-ecr-setup.sh"
echo "========================================"

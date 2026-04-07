# ap-appe-otel — Observability Stack on AWS ECS (EC2 Launch Type)

> **Rebuilt from scratch** per production requirements.  
> Removed: Alloy, Node Exporter, OTel Collector Gateway (handled by another team).  
> Stack: Prometheus + Thanos · Loki · Tempo · Grafana — all on ECS EC2.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Component Summary](#2-component-summary)
3. [AWS Resource Map](#3-aws-resource-map)
4. [Security Group Rules](#4-security-group-rules)
5. [IAM Roles & Policies](#5-iam-roles--policies)
6. [Required Manual Inputs](#6-required-manual-inputs)
7. [Execution Order — Step-by-Step](#7-execution-order--step-by-step)
8. [Required AWS Permissions](#8-required-aws-permissions)
9. [Assumptions](#9-assumptions)
10. [Validation Steps](#10-validation-steps)
11. [Troubleshooting](#11-troubleshooting)
12. [Accessing Grafana](#12-accessing-grafana)
13. [Directory Structure](#13-directory-structure)

---

## 1. Architecture Overview

```
                          VPC: vpc-0018aa4902fa67a2c
                          ┌──────────────────────────────────────────────────────┐
                          │  New Subnet: ap-appe-otel-private-subnet-1a          │
                          │  CIDR: 10.0.64.0/24  │  AZ: us-east-1a              │
                          │                                                      │
                          │  ┌─────────────┐  ┌─────────────┐                   │
                          │  │ EC2 (t3.xl) │  │ EC2 (t3.xl) │  ECS Cluster      │
                          │  │ ECS Host 1  │  │ ECS Host 2  │  ap-appe-ecs-otel  │
                          │  └──────┬──────┘  └──────┬──────┘                   │
                          │         │                 │                          │
                          │  ┌──────▼─────────────────▼───────────────────────┐ │
                          │  │           ECS Tasks (awsvpc mode)              │ │
                          │  │                                                 │ │
                          │  │  prometheus + thanos-sidecar  :9090 / :10901   │ │
                          │  │  loki                         :3100             │ │
                          │  │  tempo                        :3200 / :4317/18  │ │
                          │  │  thanos-query                 :10902            │ │
                          │  │  grafana                      :3000             │ │
                          │  │                                                 │ │
                          │  │  DNS: *.observability.local (Cloud Map)         │ │
                          │  └─────────────────────────────────────────────────┘ │
                          │                                                      │
                          │  VPC Endpoints (private routing):                    │
                          │    Gateway : S3                                      │
                          │    Interface: ECR API, ECR DKR, CloudWatch Logs,    │
                          │              SSM, SSM Messages, EC2 Messages         │
                          └──────────────────────────────────────────────────────┘
                                              │
                              ┌───────────────┼───────────────┐
                              ▼               ▼               ▼
                           S3 Bucket      ECR Repos      CloudWatch
                    ap-appe-otel-          5 repos        Log Groups
                    observability-store
                    loki/ tempo/ thanos/
```

**Inter-service communication** uses AWS Cloud Map private DNS (`observability.local`). Each task gets its own ENI (awsvpc mode), and Cloud Map registers the task IP under the service name automatically.

---

## 2. Component Summary

| Service | Image | Ports | Purpose | Removed? |
|---------|-------|-------|---------|----------|
| Prometheus | `prom/prometheus:v2.51.0` | 9090 | Metrics collection + TSDB | No |
| Thanos Sidecar | `quay.io/thanos/thanos:v0.35.1` | 10901, 10902 | Block upload to S3, Store API | No |
| Thanos Query | `quay.io/thanos/thanos:v0.35.1` | 10901, 10902 | PromQL federation | No |
| Loki | `grafana/loki:3.3.2` | 3100, 9095 | Log storage (S3 backend) | No |
| Tempo | `grafana/tempo:2.6.1` | 3200, 4317, 4318 | Trace storage (S3 backend) | No |
| Grafana | `grafana/grafana:11.0.0` | 3000 | Visualization UI | No |
| **Alloy** | — | — | OTel collector | **REMOVED** |
| **Node Exporter** | — | — | Host metrics | **REMOVED** |
| **OTel Gateway** | — | — | Handled by another team | **EXCLUDED** |

**OTLP Endpoint** (for instrumented applications sending traces):  
→ `tempo.observability.local:4317` (gRPC) or `:4318` (HTTP)

---

## 3. AWS Resource Map

| Resource | Name / ID | Notes |
|----------|-----------|-------|
| ECS Cluster | `ap-appe-ecs-otel` | NEW — created by Terraform |
| ASG | `ap-appe-otel-asg` | 2 × t3.xlarge, us-east-1a |
| Launch Template | `ap-appe-otel-ecs-lt-*` | ECS-optimized Amazon Linux 2 |
| Capacity Provider | `ap-appe-otel-ec2-cp` | Attached to cluster |
| VPC | `vpc-0018aa4902fa67a2c` | EXISTING — not modified |
| Subnet | `ap-appe-otel-private-subnet-1a` | NEW — 10.0.64.0/24, us-east-1a |
| Route Table | `ap-appe-otel-private-rt` | NEW — dedicated, no NAT by default |
| SG (instances) | `ap-appe-otel-ecs-instances-sg` | NEW |
| SG (tasks) | `ap-appe-otel-ecs-tasks-sg` | NEW |
| S3 Bucket | `ap-appe-otel-observability-store` | NEW — versioning + encryption |
| ECR Repos | `ap-appe-otel/{prometheus,loki,tempo,thanos,grafana}` | NEW |
| IAM: execution | `ap-appe-otel-ecs-execution-role` | NEW |
| IAM: task | `ap-appe-otel-ecs-task-role` | NEW |
| IAM: ec2 | `ap-appe-otel-ec2-instance-role` | NEW |
| CloudWatch LGs | `/ecs/ap-appe-otel/*` | NEW — 30d retention |
| Cloud Map NS | `observability.local` | NEW |
| VPC Endpoint: S3 | Gateway type | NEW (or reused if existing) |
| VPC Endpoints: ECR/CWL/SSM | Interface type | NEW |

---

## 4. Security Group Rules

### `ap-appe-otel-ecs-instances-sg` — EC2 ECS Hosts

| Direction | Port | Protocol | Source | Purpose |
|-----------|------|----------|--------|---------|
| Inbound | 22 | TCP | `0.0.0.0/0` ⚠ | SSH — **restrict to your admin CIDR** |
| Inbound | All | All | VPC CIDR | Internal VPC communication |
| Inbound | 32768–65535 | TCP | self | ECS ephemeral host ports |
| Outbound | All | All | `0.0.0.0/0` | ECR pulls, S3, CloudWatch |

> ⚠ **Action required**: Change SSH source from `0.0.0.0/0` to your bastion/VPN CIDR in `networking.tf` before deploying to production.

### `ap-appe-otel-ecs-tasks-sg` — ECS Task ENIs

| Direction | Port | Protocol | Source | Purpose |
|-----------|------|----------|--------|---------|
| Inbound | 9090 | TCP | VPC CIDR | Prometheus HTTP / scrape |
| Inbound | 3100 | TCP | VPC CIDR | Loki HTTP push + query |
| Inbound | 9095 | TCP | VPC CIDR | Loki gRPC |
| Inbound | 3200 | TCP | VPC CIDR | Tempo HTTP |
| Inbound | 4317 | TCP | VPC CIDR | OTLP gRPC (Tempo ingestion) |
| Inbound | 4318 | TCP | VPC CIDR | OTLP HTTP (Tempo ingestion) |
| Inbound | 3000 | TCP | VPC CIDR | Grafana UI |
| Inbound | 10901 | TCP | VPC CIDR | Thanos gRPC (Store API) |
| Inbound | 10902 | TCP | VPC CIDR | Thanos HTTP (Query UI) |
| Inbound | All | All | self | Inter-task communication |
| Outbound | All | All | `0.0.0.0/0` | S3, ECR, CloudWatch via VPC endpoints |

---

## 5. IAM Roles & Policies

### `ap-appe-otel-ecs-execution-role` (ECS Task Execution Role)
Used by the ECS agent to start containers.

| Policy | Type | Purpose |
|--------|------|---------|
| `AmazonECSTaskExecutionRolePolicy` | AWS Managed | ECR pull, CloudWatch basic |
| `ap-appe-otel-execution-logs-policy` | Inline | `logs:CreateLogGroup/Stream/PutLogEvents` on `/ecs/ap-appe-otel/*` |

### `ap-appe-otel-ecs-task-role` (Runtime Role)
Used by containers at runtime (S3, metrics).

| Policy | Type | Permissions |
|--------|------|-------------|
| `ap-appe-otel-task-s3-policy` | Inline | Full CRUD on `ap-appe-otel-observability-store` bucket |
| | | `cloudwatch:PutMetricData`, `logs:PutLogEvents` |

### `ap-appe-otel-ec2-instance-role` (EC2 Host Role)
Used by ECS EC2 instances.

| Policy | Type | Purpose |
|--------|------|---------|
| `AmazonEC2ContainerServiceforEC2Role` | AWS Managed | ECS agent registration, ECR pull |
| `AmazonSSMManagedInstanceCore` | AWS Managed | SSM Session Manager access |
| `CloudWatchAgentServerPolicy` | AWS Managed | CloudWatch metrics from host |

---

## 6. Required Manual Inputs

Before running any script, edit **`terraform/terraform.tfvars`**:

### ① EC2 Key Pair — **REQUIRED**
```hcl
key_name = "REPLACE_WITH_YOUR_KEY_PAIR_NAME"
```
Find existing key pairs:
```bash
aws ec2 describe-key-pairs --region us-east-1 --query 'KeyPairs[*].KeyName' --output table
```
Create a new one:
```bash
aws ec2 create-key-pair \
  --key-name ap-appe-otel-key \
  --region us-east-1 \
  --query 'KeyMaterial' --output text > ap-appe-otel-key.pem
chmod 400 ap-appe-otel-key.pem
```

### ② Subnet CIDR — Verify No Overlap
Default is `10.0.64.0/24`. Check existing subnets first:
```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=vpc-0018aa4902fa67a2c" \
  --query 'Subnets[*].{ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone}' \
  --output table
```
If `10.0.64.0/24` is taken, change `subnet_cidr` in `terraform.tfvars`.

### ③ Grafana Admin Password — Change Before Production
In `terraform/service_grafana.tf`, line:
```hcl
{ name = "GF_SECURITY_ADMIN_PASSWORD", value = "changeme" },
```
Change `changeme` to a strong password, or better — store it in AWS Secrets Manager and reference it via `secrets` in the container definition.

### ④ SSH CIDR — Restrict SSH Source
In `terraform/networking.tf`, the SSH ingress is currently open to `0.0.0.0/0`:
```hcl
cidr_blocks = ["0.0.0.0/0"]  # TODO: restrict to your admin CIDR
```
Change to your bastion IP or VPN CIDR (e.g., `"10.1.0.0/16"`).

### ⑤ Prometheus External Labels
In `docker/prometheus/prometheus.yml`:
```yaml
external_labels:
  cluster: "ap-appe-ecs-otel"
  environment: "production"
```
Update `cluster` and `environment` to match your actual deployment context.

---

## 7. Execution Order — Step-by-Step

```
Step 0 → Step 1 → Step 2 → Step 3 → Step 4
prereqs  tf+ECR   images   infra    validate
```

### Step 0 — Prerequisites Check
```bash
./scripts/00-prereqs.sh
```
Validates: AWS CLI, Terraform ≥ 1.5, Docker, credentials, VPC existence, subnet CIDR availability.

---

### Step 1 — Edit terraform.tfvars, then Initialize + Create ECR
```bash
# Edit the required fields first:
vim terraform/terraform.tfvars   # set key_name at minimum

./scripts/01-terraform-init.sh
```
This runs `terraform init`, `terraform plan`, and creates **only the ECR repositories** so images can be pushed before the cluster exists.

---

### Step 2 — Build and Push Docker Images
```bash
./scripts/02-build-push.sh

# Or with a specific tag:
IMAGE_TAG=v1.0.0 ./scripts/02-build-push.sh
```
Builds all 5 images for `linux/amd64` and pushes to ECR.  
**Prerequisite**: Step 1 must have completed (ECR repos must exist).

---

### Step 3 — Deploy Full Infrastructure
```bash
./scripts/03-deploy-infra.sh
```
Three interactive phases (each asks for confirmation):
- **Phase 1**: VPC endpoints, IAM, S3, CloudWatch, Cloud Map, Security Groups, Subnet
- **Phase 2**: ECS Cluster, Launch Template, ASG (launches EC2 instances), Capacity Provider
- **Phase 3**: ECS Services in dependency order — Prometheus → Loki → Tempo → Thanos Query → Grafana

**Expected time**: ~10–15 minutes total.

---

### Step 4 — Validate Deployment
```bash
./scripts/04-validate.sh
```
Checks all services, tasks, S3, ECR, IAM, VPC endpoints, log groups.

---

### Step 5 (optional) — Access Grafana
```bash
# With SSH key and EC2 public IP:
./scripts/05-grafana-access.sh /path/to/key.pem <EC2_PUBLIC_IP>

# Without public IP (uses SSM Session Manager — recommended):
./scripts/05-grafana-access.sh
```

---

## 8. Required AWS Permissions

The IAM principal running Terraform and the scripts needs the following:

```json
{
  "Statement": [
    { "Effect": "Allow", "Action": "ec2:*",              "Resource": "*" },
    { "Effect": "Allow", "Action": "ecs:*",              "Resource": "*" },
    { "Effect": "Allow", "Action": "ecr:*",              "Resource": "*" },
    { "Effect": "Allow", "Action": "iam:*",              "Resource": "*" },
    { "Effect": "Allow", "Action": "s3:*",               "Resource": "*" },
    { "Effect": "Allow", "Action": "logs:*",             "Resource": "*" },
    { "Effect": "Allow", "Action": "autoscaling:*",      "Resource": "*" },
    { "Effect": "Allow", "Action": "servicediscovery:*", "Resource": "*" },
    { "Effect": "Allow", "Action": "ssm:*",              "Resource": "*" },
    { "Effect": "Allow", "Action": "cloudwatch:*",       "Resource": "*" }
  ]
}
```

Minimum recommended: Attach `AdministratorAccess` to the deployment role, then scope it down after initial deployment.

---

## 9. Assumptions

1. **VPC `vpc-0018aa4902fa67a2c`** exists in `us-east-1` and has DNS resolution + DNS hostnames enabled.
2. **CIDR `10.0.64.0/24`** does not conflict with existing subnets in the VPC. Verify before deploying.
3. **No NAT Gateway** is assumed in this design — all AWS API traffic (ECR, S3, CloudWatch) flows through VPC Interface/Gateway Endpoints. Internet access is not required.
4. **EC2 Key Pair** must already exist in `us-east-1` (or be created per Step 6 above).
5. **Single-AZ deployment** — `us-east-1a` only. Both EC2 instances go into the same subnet. Add a second subnet in a different AZ for HA.
6. **No Load Balancer** — Grafana is accessed via SSH tunnel or SSM port forwarding. Add an ALB if you need direct browser access.
7. **Dockerfiles are unchanged** from the original tar (except `thanos/Dockerfile` which adds `COPY bucket.yml` — this is minimally necessary for Thanos sidecar S3 config).
8. **S3 bucket name** `ap-appe-otel-observability-store` must be globally unique. If already taken, change `s3_bucket` in `terraform.tfvars`.
9. **Existing VPC endpoints** — the S3 gateway endpoint check uses a `data` source. If the endpoint already exists in the VPC from another project, the gateway association script may need manual steps (noted in `vpc_endpoints.tf`).
10. **ECS-optimized AMI** is fetched dynamically from SSM Parameter Store at `terraform apply` time. This always uses the latest Amazon Linux 2 ECS AMI.
11. **Prometheus retention**: `--storage.tsdb.retention.time=15d` with Thanos uploading blocks to S3. Long-term metrics are queryable via Thanos Query.

---

## 10. Validation Steps

Run the automated script first:
```bash
./scripts/04-validate.sh
```

Then verify manually:

### ECS Cluster & Instances
```bash
aws ecs describe-clusters --clusters ap-appe-ecs-otel \
  --query 'clusters[0].{Status:status,Instances:registeredContainerInstancesCount,RunningTasks:runningTasksCount}'
```

### All Services Running
```bash
aws ecs describe-services \
  --cluster ap-appe-ecs-otel \
  --services ap-appe-otel-prometheus ap-appe-otel-loki ap-appe-otel-tempo \
             ap-appe-otel-thanos-query ap-appe-otel-grafana \
  --query 'services[*].{Name:serviceName,Status:status,Running:runningCount,Desired:desiredCount}' \
  --output table
```

### Check Logs (replace `<service>` with service name)
```bash
aws logs tail /ecs/ap-appe-otel/prometheus --follow
aws logs tail /ecs/ap-appe-otel/loki --follow
aws logs tail /ecs/ap-appe-otel/tempo --follow
aws logs tail /ecs/ap-appe-otel/grafana --follow
```

### Verify S3 Data Being Written
```bash
# After services run for ~5 minutes:
aws s3 ls s3://ap-appe-otel-observability-store/ --recursive --human-readable
```

### Verify Prometheus Scraping
```bash
# Via SSH tunnel or SSM to Grafana port, or curl from inside EC2:
curl http://prometheus.observability.local:9090/targets
curl http://prometheus.observability.local:9090/-/ready
```

### Verify Loki Ready
```bash
curl http://loki.observability.local:3100/ready
```

### Verify Tempo Ready
```bash
curl http://tempo.observability.local:3200/ready
```

### Verify Thanos Query
```bash
curl http://thanos-query.observability.local:10902/-/ready
```

---

## 11. Troubleshooting

### Tasks not starting / staying in PENDING
```bash
# Check service events:
aws ecs describe-services --cluster ap-appe-ecs-otel \
  --services ap-appe-otel-prometheus \
  --query 'services[0].events[:5]'

# Check if instances have capacity:
aws ecs describe-container-instances \
  --cluster ap-appe-ecs-otel \
  --container-instances $(aws ecs list-container-instances --cluster ap-appe-ecs-otel --query 'containerInstanceArns[]' --output text) \
  --query 'containerInstances[*].{ID:ec2InstanceId,CPU:remainingResources[?name==`CPU`].integerValue|[0],Mem:remainingResources[?name==`MEMORY`].integerValue|[0]}'
```

### Task stops immediately (crash loop)
```bash
# Get recent stopped task ARN:
TASK=$(aws ecs list-tasks --cluster ap-appe-ecs-otel \
  --service-name ap-appe-otel-loki --desired-status STOPPED \
  --query 'taskArns[0]' --output text)

# Get stop reason:
aws ecs describe-tasks --cluster ap-appe-ecs-otel --tasks $TASK \
  --query 'tasks[0].{StopCode:stopCode,StopReason:stoppedReason,Containers:containers[*].{Name:name,Reason:reason,ExitCode:exitCode}}'

# Check logs:
aws logs tail /ecs/ap-appe-otel/loki --since 1h
```

### ECR pull errors
```bash
# Verify VPC endpoints are available:
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=vpc-0018aa4902fa67a2c" \
  --query 'VpcEndpoints[*].{Service:ServiceName,State:State}' --output table

# Verify instance profile is attached:
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=ap-appe-otel-ecs-instance" \
  --query 'Reservations[*].Instances[*].{ID:InstanceId,Profile:IamInstanceProfile.Arn}'
```

### Loki or Tempo failing to write to S3
```bash
# Check task role has S3 permissions:
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::584554046133:role/ap-appe-otel-ecs-task-role \
  --action-names s3:PutObject \
  --resource-arns "arn:aws:s3:::ap-appe-otel-observability-store/*" \
  --query 'EvaluationResults[0].EvalDecision'
```

### Cloud Map / DNS not resolving
```bash
# SSH into an EC2 instance and test DNS:
nslookup loki.observability.local
nslookup prometheus.observability.local
# These should resolve to task ENI IPs
```

---

## 12. Accessing Grafana

Grafana runs in a private subnet with no public IP. Use one of:

### Option A — SSM Session Manager (recommended, no bastion needed)
```bash
./scripts/05-grafana-access.sh
# Opens http://localhost:3000 via SSM port forwarding
```

### Option B — SSH Tunnel (requires EC2 public IP or bastion)
```bash
./scripts/05-grafana-access.sh /path/to/key.pem <EC2_PUBLIC_IP>
```

### Option C — Manual
```bash
# Get Grafana task private IP:
TASK=$(aws ecs list-tasks --cluster ap-appe-ecs-otel \
  --service-name ap-appe-otel-grafana --query 'taskArns[0]' --output text)
IP=$(aws ecs describe-tasks --cluster ap-appe-ecs-otel --tasks $TASK \
  --query 'tasks[0].attachments[0].details[?name==`privateIPv4Address`].value' --output text)

# SSH tunnel (replace KEY and EC2_IP):
ssh -i key.pem -L 3000:$IP:3000 ec2-user@<EC2_IP> -N &
open http://localhost:3000
```

**Default credentials**: `admin` / `changeme` ← **Change in production**

**Pre-configured datasources** (from `docker/grafana/provisioning/datasources.yml`):
- Prometheus → `http://prometheus.observability.local:9090`
- Loki → `http://loki.observability.local:3100`
- Tempo → `http://tempo.observability.local:3200`
- Thanos → `http://thanos-query.observability.local:10902`

---

## 13. Directory Structure

```
ap-appe-otel-infra/
├── README.md                          ← This file
│
├── terraform/
│   ├── main.tf                        ← Provider + backend config
│   ├── variables.tf                   ← All variable definitions
│   ├── terraform.tfvars               ← Values (edit key_name before use)
│   ├── networking.tf                  ← Subnet + security groups
│   ├── vpc_endpoints.tf               ← S3/ECR/CWL/SSM VPC endpoints
│   ├── iam.tf                         ← 3 IAM roles + policies
│   ├── s3.tf                          ← S3 bucket with lifecycle rules
│   ├── ecr.tf                         ← 5 ECR repositories
│   ├── cluster.tf                     ← ECS cluster, ASG, launch template, CP
│   ├── cloudwatch.tf                  ← Pre-created log groups
│   ├── service_discovery.tf           ← Cloud Map namespace + services
│   ├── service_prometheus.tf          ← Prometheus + Thanos Sidecar
│   ├── service_loki.tf                ← Loki
│   ├── service_tempo.tf               ← Tempo
│   ├── service_thanos_query.tf        ← Thanos Query
│   ├── service_grafana.tf             ← Grafana
│   ├── outputs.tf                     ← Useful post-deploy outputs
│   └── templates/
│       └── user_data.sh.tpl           ← EC2 bootstrap script
│
├── docker/
│   ├── prometheus/
│   │   ├── Dockerfile                 ← UNCHANGED from original
│   │   └── prometheus.yml             ← Updated: removed alloy/node-exporter targets
│   ├── loki/
│   │   ├── Dockerfile                 ← UNCHANGED
│   │   └── loki.yml                   ← UNCHANGED
│   ├── tempo/
│   │   ├── Dockerfile                 ← UNCHANGED
│   │   └── tempo.yml                  ← UNCHANGED
│   ├── thanos/
│   │   ├── Dockerfile                 ← MINIMALLY changed: added COPY bucket.yml
│   │   └── bucket.yml                 ← NEW: S3 objstore config (env vars at runtime)
│   └── grafana/
│       ├── Dockerfile                 ← UNCHANGED
│       └── provisioning/
│           └── datasources.yml        ← UNCHANGED
│
└── scripts/
    ├── 00-prereqs.sh                  ← Pre-flight checks (run first)
    ├── 01-terraform-init.sh           ← Init + ECR repos creation
    ├── 02-build-push.sh               ← Docker build + ECR push
    ├── 03-deploy-infra.sh             ← Full infrastructure deploy
    ├── 04-validate.sh                 ← Post-deploy health checks
    ├── 05-grafana-access.sh           ← SSH tunnel / SSM to Grafana
    └── 06-teardown.sh                 ← DESTRUCTIVE: destroy all infra
```

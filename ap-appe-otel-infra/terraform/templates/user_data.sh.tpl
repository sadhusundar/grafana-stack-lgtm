#!/bin/bash
###############################################################################
# user_data.sh — ECS EC2 Instance Bootstrap
# Runs on first boot for each ECS container instance.
###############################################################################
set -euo pipefail

# ── Register with ECS cluster ─────────────────────────────────────────────────
echo ECS_CLUSTER=${cluster_name} >> /etc/ecs/ecs.config
echo ECS_ENABLE_CONTAINER_METADATA=true >> /etc/ecs/ecs.config
echo ECS_ENABLE_TASK_IAM_ROLE=true >> /etc/ecs/ecs.config
echo ECS_ENABLE_TASK_IAM_ROLE_NETWORK_HOST=true >> /etc/ecs/ecs.config
echo ECS_AWSVPC_BLOCK_IMDS=false >> /etc/ecs/ecs.config

# ── Create host-mounted data directories ──────────────────────────────────────
# These map to container volumes for stateful services.
mkdir -p /data/prometheus
mkdir -p /data/loki
mkdir -p /data/tempo
mkdir -p /data/grafana

# Grafana runs as UID 472 inside the container
chown -R 472:472 /data/grafana

# Loki and Tempo run as root (user=0), so no chown needed
chmod -R 755 /data/loki /data/tempo /data/prometheus

# ── Install SSM Agent (usually pre-installed on ECS AMI, but ensure it's up) ──
yum install -y amazon-ssm-agent 2>/dev/null || true
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

# ── Increase Docker daemon storage settings for observability workloads ────────
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "awslogs",
  "log-opts": {
    "awslogs-region": "us-east-1"
  },
  "storage-driver": "overlay2",
  "max-concurrent-downloads": 10
}
EOF

systemctl restart docker || true

echo "Bootstrap complete for ECS cluster: ${cluster_name}"

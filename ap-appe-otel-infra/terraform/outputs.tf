###############################################################################
# outputs.tf — Useful values after terraform apply
###############################################################################

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "ecs_cluster_arn" {
  description = "ECS cluster ARN"
  value       = aws_ecs_cluster.main.arn
}

output "subnet_id" {
  description = "New private subnet ID created in us-east-1a"
  value       = data.aws_subnet.otel_private.id
}

output "sg_ecs_tasks_id" {
  description = "Security group ID for ECS tasks (awsvpc)"
  value       = aws_security_group.ecs_tasks.id
}

output "sg_ecs_instances_id" {
  description = "Security group ID for EC2 ECS instances"
  value       = aws_security_group.ecs_instances.id
}

output "ecr_repositories" {
  description = "ECR repository URLs"
  value       = { for k, v in aws_ecr_repository.observability : k => v.repository_url }
}

output "s3_bucket_name" {
  description = "S3 bucket for observability storage"
  value       = aws_s3_bucket.observability.bucket
}

output "s3_bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.observability.arn
}

output "ecs_execution_role_arn" {
  description = "ECS Task Execution Role ARN"
  value       = aws_iam_role.ecs_execution.arn
}

output "ecs_task_role_arn" {
  description = "ECS Task Role ARN"
  value       = aws_iam_role.ecs_task.arn
}

output "ec2_instance_role_arn" {
  description = "EC2 Instance Role ARN"
  value       = aws_iam_role.ec2_instance.arn
}

output "asg_name" {
  description = "Auto Scaling Group name"
  value       = aws_autoscaling_group.ecs.name
}

output "capacity_provider_name" {
  description = "ECS Capacity Provider name"
  value       = aws_ecs_capacity_provider.ec2.name
}

output "service_discovery_namespace" {
  description = "Cloud Map namespace (observability.local)"
  value       = aws_service_discovery_private_dns_namespace.observability.name
}

output "grafana_access_instructions" {
  description = "How to access Grafana via SSH tunnel"
  value       = <<-INSTRUCTIONS
    ──────────────────────────────────────────────────────
    Grafana Access (SSH Tunnel)
    ──────────────────────────────────────────────────────
    1. Get the EC2 instance public IP (if in public subnet) or use SSM:
       aws ssm start-session --target <instance-id>

    2. Get the Grafana task private IP:
       TASK=$(aws ecs list-tasks --cluster ${aws_ecs_cluster.main.name} \
         --service-name ap-appe-otel-grafana \
         --query 'taskArns[0]' --output text)
       IP=$(aws ecs describe-tasks --cluster ${aws_ecs_cluster.main.name} \
         --tasks $TASK \
         --query 'tasks[0].attachments[0].details[?name==`privateIPv4Address`].value' \
         --output text)
       echo "Grafana IP: $IP"

    3. Open SSH tunnel:
       ssh -i <your-key.pem> -L 3000:$IP:3000 ec2-user@<EC2_PUBLIC_IP> -N &

    4. Open browser: http://localhost:3000
       Credentials: admin / changeme  ← CHANGE THIS IN PRODUCTION
    ──────────────────────────────────────────────────────
  INSTRUCTIONS
}

output "verify_services_command" {
  description = "CLI command to check all ECS service health"
  value       = <<-CMD
    aws ecs describe-services \
      --cluster ${aws_ecs_cluster.main.name} \
      --services \
        ap-appe-otel-prometheus \
        ap-appe-otel-loki \
        ap-appe-otel-tempo \
        ap-appe-otel-thanos-query \
        ap-appe-otel-grafana \
      --query 'services[*].{Name:serviceName,Running:runningCount,Desired:desiredCount,Status:status}' \
      --output table
  CMD
}

output "ecr_login_command" {
  description = "Command to authenticate Docker with ECR"
  value       = "aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${var.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

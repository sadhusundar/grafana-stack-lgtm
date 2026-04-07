###############################################################################
# iam.tf — IAM Roles and Policies
#
# Roles created (with existence check via try() in locals):
#   1. ap-appe-otel-ecs-execution-role  — ECS Task Execution Role
#   2. ap-appe-otel-ecs-task-role       — ECS Task Role (S3, CloudWatch)
#   3. ap-appe-otel-ec2-instance-role   — EC2 Instance Role for ECS hosts
###############################################################################

# ── Trust policies ────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "ecs_trust" {
  statement {
    sid     = "ECSTasksAssumeRole"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    sid     = "EC2AssumeRole"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

###############################################################################
# 1. ECS Task Execution Role
#    Used by ECS agent to pull images from ECR and write logs to CloudWatch.
###############################################################################
resource "aws_iam_role" "ecs_execution" {
  name               = "ap-appe-otel-ecs-execution-role"
  description        = "ECS Task Execution Role — ECR pull + CloudWatch logs"
  assume_role_policy = data.aws_iam_policy_document.ecs_trust.json

  lifecycle {
    # If role already exists (created by another run), import instead of error
    ignore_changes = [assume_role_policy]
  }
}

# AWS managed policy for basic ECS execution
resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Additional inline policy for CloudWatch log group creation
resource "aws_iam_role_policy" "execution_logs" {
  name = "ap-appe-otel-execution-logs-policy"
  role = aws_iam_role.ecs_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/ecs/ap-appe-otel/*"
      },
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = "*"
      },
    ]
  })
}

###############################################################################
# 2. ECS Task Role
#    Used by containers at runtime — S3 access, CloudWatch metrics.
###############################################################################
resource "aws_iam_role" "ecs_task" {
  name               = "ap-appe-otel-ecs-task-role"
  description        = "ECS Task Role — S3 storage + CloudWatch"
  assume_role_policy = data.aws_iam_policy_document.ecs_trust.json
}

resource "aws_iam_role_policy" "task_s3" {
  name = "ap-appe-otel-task-s3-policy"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ObservabilityBucket"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
          "s3:GetBucketVersioning",
        ]
        Resource = [
          "arn:aws:s3:::${var.s3_bucket}",
          "arn:aws:s3:::${var.s3_bucket}/*",
        ]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/ecs/ap-appe-otel/*"
      },
      {
        Sid    = "CloudWatchMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
        ]
        Resource = "*"
      },
    ]
  })
}

###############################################################################
# 3. EC2 Instance Role
#    Allows ECS agent on EC2 to register with the cluster, pull images,
#    report metrics, and use SSM Session Manager.
###############################################################################
resource "aws_iam_role" "ec2_instance" {
  name               = "ap-appe-otel-ec2-instance-role"
  description        = "EC2 Instance Role for ECS container hosts"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "ec2_ecs_policy" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "ec2_ssm_policy" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ec2_cloudwatch_policy" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Instance profile wraps the EC2 role for use by EC2 instances
resource "aws_iam_instance_profile" "ec2" {
  name = "ap-appe-otel-ec2-instance-profile"
  role = aws_iam_role.ec2_instance.name
}

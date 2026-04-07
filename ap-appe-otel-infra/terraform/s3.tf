###############################################################################
# s3.tf — S3 Bucket for Loki / Tempo / Thanos storage
###############################################################################

resource "aws_s3_bucket" "observability" {
  bucket        = var.s3_bucket
  force_destroy = false

  tags = {
    Name    = var.s3_bucket
    Purpose = "Observability storage - Loki chunks, Tempo traces, Thanos blocks"
  }
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "observability" {
  bucket                  = aws_s3_bucket.observability.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# Enable versioning for data protection
resource "aws_s3_bucket_versioning" "observability" {
  bucket = aws_s3_bucket.observability.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Server-side encryption at rest
resource "aws_s3_bucket_server_side_encryption_configuration" "observability" {
  bucket = aws_s3_bucket.observability.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Lifecycle: tiering and expiry per signal type
resource "aws_s3_bucket_lifecycle_configuration" "observability" {
  bucket = aws_s3_bucket.observability.id

  # Loki log chunks: IA after 30d, delete after 90d
  rule {
    id     = "loki-retention"
    status = "Enabled"
    filter { prefix = "loki/" }
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    expiration {
      days = 90
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }

  # Tempo traces: delete after 14d (short retention for traces)
  rule {
    id     = "tempo-retention"
    status = "Enabled"
    filter { prefix = "tempo/" }
    expiration {
      days = 14
    }
    noncurrent_version_expiration {
      noncurrent_days = 3
    }
  }

  # Thanos metric blocks: IA after 30d, delete after 365d
  rule {
    id     = "thanos-retention"
    status = "Enabled"
    filter { prefix = "thanos/" }
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    expiration {
      days = 365
    }
    noncurrent_version_expiration {
      noncurrent_days = 14
    }
  }
}

# Bucket policy: allow access only from the VPC endpoint
resource "aws_s3_bucket_policy" "observability" {
  bucket = aws_s3_bucket.observability.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowECSTaskRole"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.ecs_task.arn
        }
        Action   = ["s3:*"]
        Resource = [
          "arn:aws:s3:::${var.s3_bucket}",
          "arn:aws:s3:::${var.s3_bucket}/*",
        ]
      },
    ]
  })

  depends_on = [aws_iam_role.ecs_task]
}

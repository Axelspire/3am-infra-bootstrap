# Terraform state backend.
#
# Versioned, encrypted S3 bucket plus a DynamoDB lock table. Both are
# private to the customer's account and the ThreeAM-Deployment role.
#
# The bucket and table are created by THIS module on the customer-side
# apply. Once they exist, the AxelSpire CI Terragrunt configuration in
# 3am-deployments uses them as the remote state for every 3AM stack
# (onboarding, infra, core, ocsp, datasink).
#
# Encryption: SSE-KMS uses the AxelSpire-owned CI CMK
# (var.axelspire_artifact_kms_key_arn) rather than the customer-owned
# CMK created in kms.tf. This makes state and lock entries unreadable
# whenever AxelSpire disables the CI CMK at license end, which is the
# kill-switch the platform relies on. Customer-owned data in downstream
# stacks (audit logs, SSM SecureStrings, application data) continues to
# use the customer CMK and is unaffected by the kill switch.

resource "aws_s3_bucket" "state" {
  bucket = "3am-state-${local.account_id}-${local.region}"
  tags   = local.common_tags
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.axelspire_artifact_kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "transition-noncurrent-to-glacier"
    status = "Enabled"

    filter {}

    noncurrent_version_transition {
      noncurrent_days = 90
      storage_class   = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  dynamic "statement" {
    for_each = var.state_bucket_force_vpce != null ? [1] : []
    content {
      sid     = "DenyNonVpceAccess"
      effect  = "Deny"
      actions = ["s3:*"]
      principals {
        type        = "*"
        identifiers = ["*"]
      }
      resources = [
        aws_s3_bucket.state.arn,
        "${aws_s3_bucket.state.arn}/*",
      ]
      condition {
        test     = "StringNotEquals"
        variable = "aws:SourceVpce"
        values   = [var.state_bucket_force_vpce]
      }
    }
  }
}

resource "aws_dynamodb_table" "state_lock" {
  name         = "3am-state-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.axelspire_artifact_kms_key_arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = local.common_tags
}

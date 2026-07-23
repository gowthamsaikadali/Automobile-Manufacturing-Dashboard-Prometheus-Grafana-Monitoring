# ---------------------------------------------------------------------------
# Run this FIRST, standalone, with local state (there's no backend yet -
# that's the chicken-and-egg this folder exists to solve).
#
#   cd terraform/bootstrap
#   terraform init
#   terraform apply
#
# It creates the S3 bucket + DynamoDB lock table that the main terraform/
# config will use as its remote backend. You only ever run this bootstrap
# once per AWS account - even when you tear down and rebuild everything
# else, leave this bucket alone so your state history survives.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "ap-south-1"
}

variable "project_name" {
  default = "automobile-project"
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "tf_state" {
  # Account ID suffix keeps the bucket name globally unique without you
  # having to pick one.
  bucket = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"

  # Belt-and-suspenders: don't let a stray `terraform destroy` on the main
  # config (or a fat-fingered console click) wipe your state history.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tf_lock" {
  name         = "${var.project_name}-tf-lock"
  billing_mode = "PAY_PER_REQUEST"   # no capacity planning, cents per month
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  lifecycle {
    prevent_destroy = true
  }
}

output "state_bucket_name" {
  value = aws_s3_bucket.tf_state.bucket
}

output "lock_table_name" {
  value = aws_dynamodb_table.tf_lock.name
}

output "backend_config_block" {
  description = "Paste this into terraform/versions.tf's backend \"s3\" block"
  value = <<-EOT
    backend "s3" {
      bucket         = "${aws_s3_bucket.tf_state.bucket}"
      key            = "dev/terraform.tfstate"
      region         = "${var.aws_region}"
      dynamodb_table = "${aws_dynamodb_table.tf_lock.name}"
      encrypt        = true
    }
  EOT
}

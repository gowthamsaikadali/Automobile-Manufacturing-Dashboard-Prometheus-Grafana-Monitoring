# Same bucket/lock table as phase 1 - just a different state file (key), so
# the two roots never collide or block each other.
terraform {
  backend "s3" {
    bucket         = "REPLACE-WITH-YOUR-STATE-BUCKET-NAME"
    key            = "autoforge/dev-phase2/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "autoforge-terraform-locks"
    encrypt        = true
  }
}

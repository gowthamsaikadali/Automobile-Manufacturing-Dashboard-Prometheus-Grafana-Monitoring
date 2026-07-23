# Fill in the bucket/table names that the bootstrap module created for you,
# then run: terraform init
terraform {
  backend "s3" {
    bucket         = "autoforge-tfstate-gowtham-2026"
    key            = "autoforge/dev/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "autoforge-terraform-locks"
    encrypt        = true
  }
}

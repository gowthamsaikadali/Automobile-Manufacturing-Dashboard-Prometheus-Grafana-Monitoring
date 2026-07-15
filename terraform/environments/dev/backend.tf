# Fill in the bucket/table names that the bootstrap module created for you,
# then run: terraform init
terraform {
  backend "s3" {
    bucket         = "REPLACE-WITH-YOUR-STATE-BUCKET-NAME"
    key            = "autoforge/dev/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "autoforge-terraform-locks"
    encrypt        = true
  }
}

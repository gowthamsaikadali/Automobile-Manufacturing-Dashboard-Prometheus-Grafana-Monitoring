terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # State lives in the bucket/table created by terraform/bootstrap - apply
  # that folder once, first, then fill in the exact values it prints via
  # `terraform output backend_config_block` (bucket name includes your
  # account ID so it can't be guessed here).
  backend "s3" {
    bucket         = "automobile-project-tfstate-<YOUR_ACCOUNT_ID>"
    key            = "dev/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "automobile-project-tf-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

# These two providers talk to the EKS cluster this same config creates -
# that's why they're configured from the eks module's outputs.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}

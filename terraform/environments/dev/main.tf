terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

variable "region" { default = "ap-south-1" }
variable "account_id" {}
variable "github_org" {}
variable "github_repo" { default = "Automobile-Manufacturing-Dashboard-Prometheus-Grafana-Monitoring" }
variable "db_password" { sensitive = true }

provider "aws" {
  region = var.region
}

# ---------------------------------------------------------------------------
# This root module provisions everything that does NOT depend on the ALB
# existing: network, EKS, ECR, RDS, and IAM roles (GitHub OIDC + External
# Secrets IRSA). A plain `terraform apply` here is always safe to run -
# there is nothing in this state file that looks up the ALB.
#
# WAFv2 and CloudWatch alarms (which DO need the ALB to exist first) live in
# a separate root module: ../dev-phase2. Run that one AFTER you've deployed
# the app with Helm and the ALB has actually been created. See README.md.
# ---------------------------------------------------------------------------

module "vpc" {
  source       = "../../modules/vpc"
  name         = "autoforge"
  cluster_name = "autoforge-eks"
}

module "eks" {
  source             = "../../modules/eks"
  vpc_id             = module.vpc.vpc_id
  public_subnet_ids  = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids
  node_instance_type = "t3.small"
}

module "ecr" {
  source    = "../../modules/ecr"
  repo_name = "autoforge-app"
}

module "rds" {
  source         = "../../modules/rds"
  identifier     = "autoforge-mysql"
  vpc_id         = module.vpc.vpc_id
  subnet_ids     = module.vpc.private_subnet_ids
  allowed_sg_ids = [module.eks.cluster_security_group_id]
  db_password    = var.db_password
}

module "iam" {
  source                     = "../../modules/iam"
  github_org                 = var.github_org
  github_repo                = var.github_repo
  account_id                 = var.account_id
  ecr_repo_arn               = "arn:aws:ecr:${var.region}:${var.account_id}:repository/${module.ecr.repository_name}"
  eks_oidc_provider_arn      = module.eks.oidc_provider_arn
  eks_oidc_provider_url      = module.eks.oidc_provider_url
  cluster_name               = module.eks.cluster_name
  secrets_manager_arn_prefix = "arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:autoforge/"
}

output "vpc_id" { value = module.vpc.vpc_id }
output "eks_cluster_name" { value = module.eks.cluster_name }
output "ecr_repository_url" { value = module.ecr.repository_url }
output "rds_endpoint" { value = module.rds.endpoint }
output "github_deploy_role_arn" { value = module.iam.github_deploy_role_arn }
output "external_secrets_role_arn" { value = module.iam.external_secrets_role_arn }
output "alb_controller_role_arn" {value = module.iam.alb_controller_role_arn}
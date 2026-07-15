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
variable "alarm_email" {}

provider "aws" {
  region = var.region
}

# ---------------------------------------------------------------------------
# NETWORK
# ---------------------------------------------------------------------------
module "vpc" {
  source       = "../../modules/vpc"
  name         = "autoforge"
  cluster_name = "autoforge-eks"
}

# ---------------------------------------------------------------------------
# EKS
# ---------------------------------------------------------------------------
module "eks" {
  source              = "../../modules/eks"
  vpc_id              = module.vpc.vpc_id
  public_subnet_ids   = module.vpc.public_subnet_ids
  private_subnet_ids  = module.vpc.private_subnet_ids
  node_instance_type  = "t3.small"
}

# ---------------------------------------------------------------------------
# ECR
# ---------------------------------------------------------------------------
module "ecr" {
  source    = "../../modules/ecr"
  repo_name = "autoforge-app"
}

# ---------------------------------------------------------------------------
# RDS (allow access from EKS cluster security group only)
# ---------------------------------------------------------------------------
module "rds" {
  source         = "../../modules/rds"
  identifier     = "autoforge-mysql"
  vpc_id         = module.vpc.vpc_id
  subnet_ids     = module.vpc.private_subnet_ids
  allowed_sg_ids = [module.eks.cluster_security_group_id]
  db_password    = var.db_password
}

# ---------------------------------------------------------------------------
# IAM (GitHub OIDC deploy role + External Secrets IRSA)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# WAFv2 (protects the ALB). NOTE: the ALB only exists once the Helm chart's
# ingress has been applied to the cluster and the AWS Load Balancer
# Controller has provisioned it. This is a two-phase apply:
#   Phase 1: terraform apply -target=module.vpc -target=module.eks \
#            -target=module.ecr -target=module.rds -target=module.iam
#            -> then install ALB controller + helm install the app
#   Phase 2: terraform apply
#            -> now module.waf's data source finds the ALB and finishes
#               the WAF association + CloudWatch alarms
# ---------------------------------------------------------------------------
module "waf" {
  source   = "../../modules/waf"
  alb_name = "autoforge-alb"
}

# ---------------------------------------------------------------------------
# MONITORING (CloudWatch alarms + SNS)
# ---------------------------------------------------------------------------
module "monitoring" {
  source           = "../../modules/monitoring"
  alarm_email      = var.alarm_email
  rds_instance_id  = "autoforge-mysql"
  alb_arn_suffix   = module.waf.alb_arn_suffix
  eks_cluster_name = module.eks.cluster_name
}

output "eks_cluster_name" { value = module.eks.cluster_name }
output "ecr_repository_url" { value = module.ecr.repository_url }
output "rds_endpoint" { value = module.rds.endpoint }
output "github_deploy_role_arn" { value = module.iam.github_deploy_role_arn }
output "external_secrets_role_arn" { value = module.iam.external_secrets_role_arn }
output "sns_topic_arn" { value = module.monitoring.sns_topic_arn }
output "alb_dns_name" { value = module.waf.alb_dns_name }

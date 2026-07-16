terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

variable "region" { default = "ap-south-1" }
variable "alarm_email" {
  description = "Email to receive CloudWatch alarm notifications"
  type        = string
}
variable "alb_name" {
  description = "Must match alb.ingress.kubernetes.io/load-balancer-name in helm/autoforge/values.yaml"
  default     = "autoforge-alb"
}
variable "phase1_state_bucket" {
  description = "Same bucket you used in phase 1 (terraform/environments/dev/backend.tf)"
  type        = string
}

provider "aws" {
  region = var.region
}

# ---------------------------------------------------------------------------
# Pulls outputs (like the EKS cluster name) straight from phase 1's state
# file, so you never have to copy/paste values between the two applies.
# ---------------------------------------------------------------------------
data "terraform_remote_state" "phase1" {
  backend = "s3"
  config = {
    bucket = var.phase1_state_bucket
    key    = "autoforge/dev/terraform.tfstate"
    region = var.region
  }
}

# ---------------------------------------------------------------------------
# ONLY RUN THIS after the app has been deployed via Helm and the ALB named
# `autoforge-alb` actually exists. Check first with:
#   kubectl get ingress autoforge-app-ingress -n autoforge
# If that doesn't show a hostname yet, STOP - go finish the Helm deploy step
# in the README before running this root module.
# ---------------------------------------------------------------------------
module "waf" {
  source   = "../../modules/waf"
  alb_name = var.alb_name
}

module "monitoring" {
  source           = "../../modules/monitoring"
  alarm_email      = var.alarm_email
  rds_instance_id  = "autoforge-mysql"
  alb_arn_suffix   = module.waf.alb_arn_suffix
  eks_cluster_name = data.terraform_remote_state.phase1.outputs.eks_cluster_name
}

output "web_acl_arn" { value = module.waf.web_acl_arn }
output "alb_dns_name" { value = module.waf.alb_dns_name }
output "sns_topic_arn" { value = module.monitoring.sns_topic_arn }

variable "name" { default = "autoforge-waf" }
variable "alb_name" {
  description = "Name of the ALB created by the AWS Load Balancer Controller (must match alb.ingress.kubernetes.io/load-balancer-name in the Helm ingress annotation)"
  default     = "autoforge-alb"
}

# Looked up rather than hardcoded, since the ALB only exists after the Helm
# ingress has been applied to the cluster (apply this module AFTER that step,
# e.g. `terraform apply -target=module.waf` on a second pass).
data "aws_lb" "app" {
  name = var.alb_name
}

resource "aws_wafv2_web_acl" "this" {
  name        = var.name
  scope       = "REGIONAL"
  description = "WAF for AutoForge ALB - common rule set + rate limiting"

  default_action {
    allow {}
  }

  rule {
    name     = "AWS-CommonRuleSet"
    priority = 1
    override_action { none {} }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "commonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-SQLiRuleSet"
    priority = 2
    override_action { none {} }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "sqliRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "RateLimit"
    priority = 3
    action { block {} }
    statement {
      rate_based_statement {
        limit              = 2000 # requests per 5-min window per IP
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rateLimit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "autoforgeWaf"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = data.aws_lb.app.arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}

output "web_acl_arn" { value = aws_wafv2_web_acl.this.arn }
output "alb_arn_suffix" { value = data.aws_lb.app.arn_suffix }
output "alb_dns_name" { value = data.aws_lb.app.dns_name }

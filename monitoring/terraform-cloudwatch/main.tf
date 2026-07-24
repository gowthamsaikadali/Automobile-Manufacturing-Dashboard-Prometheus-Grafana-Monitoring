terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region"        { default = "ap-south-1" }
variable "notification_email" { type = string }        # e.g. you@example.com
variable "rds_instance_id"   { type = string }          # e.g. automobile-db
variable "alb_arn_suffix"    { type = string }          # from ALB, e.g. app/automobile-project-dev-alb/xxxxxxxx
variable "eks_cluster_name"  { type = string }          # e.g. automobile-eks-dev

# ---------------------------------------------------------------------------
# SNS topic - fan-out to email (and optionally Slack via AWS Chatbot)
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name = "automobile-app-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# Optional: route the same SNS topic into a Slack channel using AWS Chatbot.
# Create the Chatbot Slack workspace/channel config once in the console
# (Chatbot requires one-time OAuth to your Slack workspace), then reference
# its ARN here, or manage it with the aws_chatbot_slack_channel_configuration
# resource if your Terraform AWS provider version supports it.

# ---------------------------------------------------------------------------
# RDS CPU alarm
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "automobile-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods   = 3
  metric_name          = "CPUUtilization"
  namespace            = "AWS/RDS"
  period               = 300
  statistic            = "Average"
  threshold            = 80
  alarm_description    = "RDS CPU utilization above 80% for 15 minutes"
  dimensions           = { DBInstanceIdentifier = var.rds_instance_id }
  alarm_actions        = [aws_sns_topic.alerts.arn]
  ok_actions            = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage_low" {
  alarm_name          = "automobile-rds-storage-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods   = 1
  metric_name          = "FreeStorageSpace"
  namespace            = "AWS/RDS"
  period               = 300
  statistic            = "Average"
  threshold            = 2000000000  # 2 GB
  alarm_description    = "RDS free storage below 2GB"
  dimensions           = { DBInstanceIdentifier = var.rds_instance_id }
  alarm_actions        = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------------------
# ALB alarms - 5xx error rate and target response time (latency)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "alb_5xx_high" {
  alarm_name          = "automobile-alb-5xx-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods   = 2
  metric_name          = "HTTPCode_Target_5XX_Count"
  namespace            = "AWS/ApplicationELB"
  period               = 300
  statistic            = "Sum"
  threshold            = 10
  alarm_description    = "More than 10 5xx responses in 5 minutes"
  dimensions           = { LoadBalancer = var.alb_arn_suffix }
  alarm_actions        = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "alb_latency_high" {
  alarm_name          = "automobile-alb-latency-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods   = 3
  metric_name          = "TargetResponseTime"
  namespace            = "AWS/ApplicationELB"
  period               = 300
  statistic            = "Average"
  threshold            = 1  # seconds
  alarm_description    = "ALB target response time above 1s for 15 minutes"
  dimensions           = { LoadBalancer = var.alb_arn_suffix }
  alarm_actions        = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------------------
# EKS node CPU alarm (via Container Insights - enable it on the cluster first,
# see enable-container-insights.sh in this folder)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "eks_node_cpu_high" {
  alarm_name          = "automobile-eks-node-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods   = 3
  metric_name          = "node_cpu_utilization"
  namespace            = "ContainerInsights"
  period               = 300
  statistic            = "Average"
  threshold            = 80
  alarm_description    = "EKS worker node CPU above 80% for 15 minutes"
  dimensions           = { ClusterName = var.eks_cluster_name }
  alarm_actions        = [aws_sns_topic.alerts.arn]
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

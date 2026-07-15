variable "alarm_email" {
  description = "Email to receive CloudWatch alarm notifications"
  type        = string
}
variable "rds_instance_id" {}
variable "alb_arn_suffix" {
  description = "ARN suffix of the ALB (from aws_lb.this.arn_suffix) for CloudWatch dimensions"
}
variable "eks_cluster_name" {}
variable "asg_name" {
  description = "Auto Scaling Group name backing the EKS node group (for CPU alarms)"
  default     = ""
}

resource "aws_sns_topic" "alerts" {
  name = "autoforge-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# --- RDS: CPU > 80% ---
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "autoforge-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  dimensions          = { DBInstanceIdentifier = var.rds_instance_id }
}

# --- RDS: Free storage low (< 2 GB) ---
resource "aws_cloudwatch_metric_alarm" "rds_storage_low" {
  alarm_name          = "autoforge-rds-storage-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 2147483648 # 2 GB in bytes
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions          = { DBInstanceIdentifier = var.rds_instance_id }
}

# --- RDS: Connection count spike ---
resource "aws_cloudwatch_metric_alarm" "rds_connections_high" {
  alarm_name          = "autoforge-rds-connections-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 50
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions          = { DBInstanceIdentifier = var.rds_instance_id }
}

# --- ALB: 5xx error rate ---
resource "aws_cloudwatch_metric_alarm" "alb_5xx_high" {
  alarm_name          = "autoforge-alb-5xx-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  treat_missing_data  = "notBreaching"
}

# --- ALB: p95 target response time high ---
resource "aws_cloudwatch_metric_alarm" "alb_latency_high" {
  alarm_name          = "autoforge-alb-latency-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  extended_statistic  = "p95"
  threshold           = 2 # seconds
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  treat_missing_data  = "notBreaching"
}

# --- EC2/ASG (worker nodes): CPU > 80% ---
resource "aws_cloudwatch_metric_alarm" "node_cpu_high" {
  count               = var.asg_name != "" ? 1 : 0
  alarm_name          = "autoforge-node-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.alerts.arn]
  dimensions          = { AutoScalingGroupName = var.asg_name }
}

# --- Log group for the application (if not shipping via Fluent Bit/EFK) ---
resource "aws_cloudwatch_log_group" "app" {
  name              = "/autoforge/${var.eks_cluster_name}/app"
  retention_in_days = 14
}

output "sns_topic_arn" { value = aws_sns_topic.alerts.arn }
output "app_log_group" { value = aws_cloudwatch_log_group.app.name }

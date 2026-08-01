variable "aws_region" {
  default = "ap-south-1"
}

variable "project_name" {
  default = "automobile-project"
}

variable "environment" {
  default = "dev"
}

variable "vpc_cidr" {
  default = "10.20.0.0/16"
}

# c7i-flex.large (2 vCPU / 4 GB) - t3.small didn't have enough headroom
# once Prometheus/Grafana/Alertmanager/Loki run alongside the app.
# NOTE: this instance type is NOT AWS Free Tier eligible (only
# t2.micro/t3.micro are) - it bills hourly regardless of activity.
variable "eks_node_instance_types" {
  default = ["c7i-flex.large"]
}

variable "eks_node_desired_size" {
  default = 2
}

variable "eks_node_min_size" {
  default = 2
}

variable "eks_node_max_size" {
  default = 3
}

variable "db_instance_class" {
  default = "db.t3.micro"   # free-tier eligible, paired with gp2 storage in rds.tf
}

variable "db_allocated_storage" {
  default = 20
}

variable "db_name" {
  default = "automobile_db"
}

variable "db_username" {
  default = "admin"
}

variable "kubernetes_version" {
  # 1.30 reached end of extended EKS support on 2026-07-23 - hence the
  # console warning. 1.34 has a full standard-support runway from here.
  default = "1.34"
}

variable "additional_admin_arns" {
  description = <<-EOT
    IAM user/role ARNs (besides whoever runs `terraform apply`) that should
    get EKS access entries with cluster-admin. This is what fixes "Your
    current IAM principal doesn't have access to Kubernetes objects" for
    anyone viewing the console with different credentials than the ones
    Terraform used - e.g. your regular console login vs. a CLI profile.
    Find your own ARN with: aws sts get-caller-identity --query Arn
  EOT
  type    = list(string)
  default = []
}

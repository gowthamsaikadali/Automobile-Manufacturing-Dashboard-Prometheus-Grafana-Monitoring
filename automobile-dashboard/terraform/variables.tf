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

# Free-tier / low-cost conscious sizing - bump these if pods keep pending
variable "eks_node_instance_types" {
  default = ["t3.small"]
}

variable "eks_node_desired_size" {
  default = 2
}

variable "eks_node_min_size" {
  default = 2
}

variable "eks_node_max_size" {
  default = 4
}

variable "db_instance_class" {
  default = "db.t3.micro"
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

variable "db_password" {
  description = "RDS master password - pass with -var or TF_VAR_db_password env var, never commit it"
  type        = string
  sensitive   = true
}

variable "kubernetes_version" {
  default = "1.30"
}

variable "identifier" { default = "autoforge-mysql" }
variable "vpc_id" {}
variable "subnet_ids" { type = list(string) }
variable "allowed_sg_ids" {
  type        = list(string)
  description = "Security groups (e.g. EKS node SG) allowed to reach RDS on 3306"
}
variable "db_name" { default = "autoforge" }
variable "db_username" { default = "autoforge_admin" }
variable "db_password" { sensitive = true }
variable "instance_class" { default = "db.t3.micro" }
variable "allocated_storage" { default = 20 }
variable "multi_az" { default = false }

resource "aws_db_subnet_group" "this" {
  name       = "${var.identifier}-subnet-group"
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "rds" {
  name_prefix = "${var.identifier}-sg-"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = var.allowed_sg_ids
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "this" {
  identifier             = var.identifier
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = var.instance_class
  allocated_storage      = var.allocated_storage
  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  multi_az               = var.multi_az
  publicly_accessible     = false
  skip_final_snapshot    = true
  backup_retention_period = 3

  # Ships slow query / error / general logs to CloudWatch Logs for the
  # monitoring stack to pick up
  enabled_cloudwatch_logs_exports = ["error", "general", "slowquery"]
}

output "endpoint" { value = aws_db_instance.this.address }
output "port" { value = aws_db_instance.this.port }
output "db_name" { value = aws_db_instance.this.db_name }
output "security_group_id" { value = aws_security_group.rds.id }

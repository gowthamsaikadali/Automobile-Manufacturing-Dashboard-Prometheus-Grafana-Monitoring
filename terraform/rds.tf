# ---------------------------------------------------------------------------
# Auto-generated master password - you never type or invent one. It's
# created once, stored in Secrets Manager, and Terraform reads it back on
# every subsequent apply/plan so it stays stable across runs.
# ---------------------------------------------------------------------------
resource "random_password" "db" {
  length           = 24
  special          = true
  override_special = "!#$%^&*()-_=+"
}

resource "aws_secretsmanager_secret" "db_credentials" {
  name = "${var.project_name}-${var.environment}-db-credentials"
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    host     = aws_db_instance.automobile.address
    port     = aws_db_instance.automobile.port
    dbname   = var.db_name
  })
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-${var.environment}-rds-sg"
  description = "Allow MySQL from EKS nodes only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "MySQL from EKS worker nodes"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_db_instance" "automobile" {
  identifier     = "${var.project_name}-${var.environment}-db"
  engine         = "mysql"
  engine_version = "8.0"

  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result
  port     = 3306

  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false   # private subnets only - reachable from the cluster, not the internet

  multi_az                  = false   # set true for production HA (doubles cost)
  backup_retention_period   = 7
  skip_final_snapshot       = true    # set false + provide final_snapshot_identifier for real prod
  deletion_protection       = false   # flip to true once this is a "keep forever" environment
  auto_minor_version_upgrade = true

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

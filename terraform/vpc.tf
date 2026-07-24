data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "${var.project_name}-${var.environment}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets  = ["10.20.0.0/24", "10.20.1.0/24"]
  private_subnets = ["10.20.10.0/24", "10.20.11.0/24"]
  database_subnets = ["10.20.20.0/24", "10.20.21.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true   # one NAT for both AZs - saves ~$32/mo vs one per AZ
  enable_dns_hostnames = true
  enable_dns_support   = true

  create_database_subnet_group = true

  # Required tags so the AWS Load Balancer Controller and EKS can
  # auto-discover subnets for public/internal ALBs and node placement.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                                       = "1"
    "kubernetes.io/cluster/${var.project_name}-${var.environment}-eks" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"                              = "1"
    "kubernetes.io/cluster/${var.project_name}-${var.environment}-eks" = "shared"
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

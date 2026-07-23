module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = "${var.project_name}-${var.environment}-eks"
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets   # worker nodes in private subnets

  cluster_endpoint_public_access  = true    # so you can kubectl from your laptop without a bastion
  cluster_endpoint_private_access = true

  enable_irsa = true   # required for aws-load-balancer-controller, external-secrets, cluster-autoscaler IRSA roles

  eks_managed_node_groups = {
    default = {
      instance_types = var.eks_node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.eks_node_min_size
      max_size     = var.eks_node_max_size
      desired_size = var.eks_node_desired_size

      labels = { role = "app" }
    }
  }

  # Lets your current IAM user/role admin the cluster via kubectl immediately
  # after apply, without extra aws-auth wrangling.
  enable_cluster_creator_admin_permissions = true

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# So `kubectl` works right after apply:
#   aws eks update-kubeconfig --name automobile-project-dev-eks --region ap-south-1

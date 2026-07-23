output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.automobile_app.repository_url
}

output "rds_endpoint" {
  value = aws_db_instance.automobile.address
}

output "rds_port" {
  value = aws_db_instance.automobile.port
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

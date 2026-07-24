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

output "db_credentials_secret_name" {
  description = "Retrieve the auto-generated DB password with: aws secretsmanager get-secret-value --secret-id <this value> --query SecretString --output text"
  value       = aws_secretsmanager_secret.db_credentials.name
}

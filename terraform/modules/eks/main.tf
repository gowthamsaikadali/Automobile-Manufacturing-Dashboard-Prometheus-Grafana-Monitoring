variable "cluster_name" { default = "autoforge-eks" }
variable "cluster_version" { default = "1.30" }
variable "vpc_id" {}
variable "public_subnet_ids" { type = list(string) }
variable "private_subnet_ids" { type = list(string) }
variable "node_instance_type" { default = "t3.small" }
variable "node_desired_size" { default = 2 }
variable "node_min_size" { default = 2 }
variable "node_max_size" { default = 4 }

variable "use_public_subnets_for_nodes" {
  description = "true = cost-conscious (no NAT needed); false = private subnets (needs NAT)"
  default     = true
}

###########################################################
# EKS Cluster Role
###########################################################

data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

###########################################################
# EKS Cluster
###########################################################

resource "aws_eks_cluster" "this" {

  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  vpc_config {

    subnet_ids = concat(
      var.public_subnet_ids,
      var.private_subnet_ids
    )

    endpoint_public_access  = true
    endpoint_private_access = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy
  ]
}

###########################################################
# OIDC Provider
###########################################################

data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {

  url = aws_eks_cluster.this.identity[0].oidc[0].issuer

  client_id_list = [
    "sts.amazonaws.com"
  ]

  thumbprint_list = [
    data.tls_certificate.eks.certificates[0].sha1_fingerprint
  ]
}

###########################################################
# Node IAM Role
###########################################################

data "aws_iam_policy_document" "node_assume" {

  statement {

    actions = [
      "sts:AssumeRole"
    ]

    principals {

      type = "Service"

      identifiers = [
        "ec2.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_role" "node" {

  name = "${var.cluster_name}-node-role"

  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_role_policy_attachment" "node_ebs_csi" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
###########################################################
# NEW - EBS CSI Driver IAM Role
###########################################################

data "aws_iam_policy_document" "ebs_csi_assume" {

  statement {

    actions = [
      "sts:AssumeRoleWithWebIdentity"
    ]

    principals {

      type = "Federated"

      identifiers = [
        aws_iam_openid_connect_provider.eks.arn
      ]
    }

    condition {

      test = "StringEquals"

      variable = "${replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:sub"

      values = [
        "system:serviceaccount:kube-system:ebs-csi-controller-sa"
      ]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {

  name = "${var.cluster_name}-ebs-csi-role"

  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {

  role = aws_iam_role.ebs_csi.name

  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

###########################################################
# Node Group
###########################################################

resource "aws_eks_node_group" "default" {

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-ng"

  node_role_arn = aws_iam_role.node.arn

  subnet_ids = var.use_public_subnets_for_nodes ? var.public_subnet_ids : var.private_subnet_ids

  instance_types = [
    var.node_instance_type
  ]

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
    aws_iam_role_policy_attachment.node_ssm,
    aws_iam_role_policy_attachment.node_ebs_csi
  ]
}

###########################################################
# Install EBS CSI Driver
###########################################################

resource "aws_eks_addon" "ebs_csi" {

  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_iam_role_policy_attachment.ebs_csi,
    aws_eks_node_group.default
  ]
}

###########################################################
# Outputs
###########################################################

output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_ca" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  value = replace(
    aws_eks_cluster.this.identity[0].oidc[0].issuer,
    "https://",
    ""
  )
}

output "cluster_security_group_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}
variable "github_org" {}
variable "github_repo" {}
variable "account_id" {}
variable "ecr_repo_arn" {}
variable "eks_oidc_provider_arn" {}
variable "eks_oidc_provider_url" {}
variable "cluster_name" {}
variable "secrets_manager_arn_prefix" {
  description = "ARN prefix for the Secrets Manager secret(s) External Secrets Operator may read"
}

# ---------------------------------------------------------------------------
# 1. GitHub Actions OIDC provider + deploy role (no long-lived AWS keys in CI)
# ---------------------------------------------------------------------------
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name               = "autoforge-github-actions-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
}

# Least-privilege: push to ECR + describe/update the EKS cluster only
data "aws_iam_policy_document" "github_deploy_perms" {
  statement {
    sid       = "ECRPush"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "ECRRepo"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage", "ecr:PutImage", "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart", "ecr:CompleteLayerUpload"
    ]
    resources = [var.ecr_repo_arn]
  }
  statement {
    sid       = "EKSDescribe"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:aws:eks:*:${var.account_id}:cluster/${var.cluster_name}"]
  }
}

resource "aws_iam_role_policy" "github_deploy_perms" {
  name   = "autoforge-github-deploy-perms"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy_perms.json
}

# ---------------------------------------------------------------------------
# 2. External Secrets Operator IRSA role (reads AWS Secrets Manager)
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "eso_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.eks_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_provider_url}:sub"
      values   = ["system:serviceaccount:autoforge:external-secrets-sa"]
    }
  }
}

resource "aws_iam_role" "eso" {
  name               = "autoforge-external-secrets-irsa"
  assume_role_policy = data.aws_iam_policy_document.eso_assume.json
}

data "aws_iam_policy_document" "eso_perms" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["${var.secrets_manager_arn_prefix}*"]
  }
}

resource "aws_iam_role_policy" "eso_perms" {
  name   = "autoforge-eso-perms"
  role   = aws_iam_role.eso.id
  policy = data.aws_iam_policy_document.eso_perms.json
}

output "github_deploy_role_arn" { value = aws_iam_role.github_deploy.arn }
output "external_secrets_role_arn" { value = aws_iam_role.eso.arn }

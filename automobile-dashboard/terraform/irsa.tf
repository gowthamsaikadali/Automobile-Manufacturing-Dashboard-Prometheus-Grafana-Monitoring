# ---------------------------------------------------------------------------
# The AWS Load Balancer Controller is what turns your k8s/ingress.yaml into
# a real ALB. It needs an IAM policy + a role trusted by the cluster's OIDC
# provider (IRSA), bound to a ServiceAccount in kube-system.
# ---------------------------------------------------------------------------

# Pull the official, always-current policy straight from the project's repo
# instead of hand-copying a huge JSON blob that goes stale.
data "http" "lbc_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.14.1/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "lbc" {
  name   = "${var.project_name}-${var.environment}-AWSLoadBalancerControllerIAMPolicy"
  policy = data.http.lbc_iam_policy.response_body
}

module "lbc_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-account-eks"
  version = "~> 5.44"

  role_name = "${var.project_name}-${var.environment}-lbc-role"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = module.lbc_irsa_role.iam_role_name
  policy_arn = aws_iam_policy.lbc.arn
}

resource "kubernetes_service_account" "lbc" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = module.lbc_irsa_role.iam_role_arn
    }
  }
  depends_on = [module.eks]
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "serviceAccount.create"
    value = "false"
  }
  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.lbc.metadata[0].name
  }
  set {
    name  = "region"
    value = var.aws_region
  }
  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  depends_on = [kubernetes_service_account.lbc]
}

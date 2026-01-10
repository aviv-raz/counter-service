data "aws_partition" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  vpc_name = "${var.cluster_name}-vpc"

  ecr_repo_name = "counter-service"

  gha_role_name = "${var.cluster_name}-gha-deployer"

  gha_sub = "repo:${var.github_owner}/${var.github_repo}:environment:${var.github_environment}"
}

############################
# VPC
############################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.vpc_name
  cidr = "10.0.0.0/16"

  azs = local.azs
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  # These subnet tags tell EKS and AWS Load Balancers which subnets can be used
  # for creating public and internal load balancers (for Services/Ingress).
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

############################
# KMS for EKS secrets encryption
############################
resource "aws_kms_key" "eks_secrets" {
  description             = "KMS key for EKS secrets encryption (${var.cluster_name})"
  deletion_window_in_days = 10
  enable_key_rotation     = true
}

resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${var.cluster_name}-eks-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}

############################
# EKS
############################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name       = var.cluster_name
  kubernetes_version = var.k8s_version

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  authentication_mode = "API_AND_CONFIG_MAP"

  enabled_log_types = [ "audit" ]

  encryption_config = {
    resources = ["secrets"]
    provider_key_arn = aws_kms_key.eks_secrets.arn
  }

  upgrade_policy = {
    support_type = "STANDARD"
  }

  # Node Group
  eks_managed_node_groups = {
    ng1 = {
      name = "${var.cluster_name}-ng1"

      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = 1
      max_size     = 2
      desired_size = 1

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 30
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }
  }

  enable_irsa = true

  addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_irsa_role.arn
    }
  }

  access_entries = {
    gha = {
      principal_arn = aws_iam_role.gha_deployer.arn

      policy_associations = {
        admin = {
          policy_arn = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }
}

############################
# IRSA - IAM role for SA of ebs csi
############################
module "ebs_csi_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.3"

  name                  = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

############################
# ECR
############################
resource "aws_ecr_repository" "counter" {
  name                 = local.ecr_repo_name
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "counter" {
  repository = aws_ecr_repository.counter.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 50 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 50
        }
        action = { type = "expire" }
      }
    ]
  })
}

############################
# OIDC provider for GitHub Actions
############################
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]

  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

data "aws_iam_policy_document" "gha_trust" {
  statement {
    effect  = "Allow"
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
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.gha_sub]
    }
  }
}

resource "aws_iam_role" "gha_deployer" {
  name               = local.gha_role_name
  assume_role_policy = data.aws_iam_policy_document.gha_trust.json
}

############################
# IAM permissions for GitHub Actions
# 1) ECR push/pull
# 2) EKS DescribeCluster (For able to run: aws eks update-kubeconfig / get-token)
############################
data "aws_iam_policy_document" "gha_permissions" {
  statement {
    sid     = "ECRAuth"
    effect  = "Allow"
    actions = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "ECRRepoActions"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:DescribeRepositories",
      "ecr:DescribeImages",
      "ecr:ListImages"
    ]
    resources = [aws_ecr_repository.counter.arn]
  }

  statement {
    sid     = "EKSDescribe"
    effect  = "Allow"
    actions = ["eks:DescribeCluster"]
    resources = [module.eks.cluster_arn]
  }
}

resource "aws_iam_policy" "gha_permissions" {
  name   = "${var.cluster_name}-gha-permissions"
  policy = data.aws_iam_policy_document.gha_permissions.json
}

resource "aws_iam_role_policy_attachment" "gha_permissions" {
  role       = aws_iam_role.gha_deployer.name
  policy_arn = aws_iam_policy.gha_permissions.arn
}


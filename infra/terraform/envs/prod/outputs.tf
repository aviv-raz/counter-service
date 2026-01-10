output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.aws_region
}

output "ecr_repository_url" {
  value = aws_ecr_repository.counter.repository_url
}

output "gha_role_arn" {
  value = aws_iam_role.gha_deployer.arn
}


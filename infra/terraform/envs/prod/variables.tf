variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "k8s_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.29"
}

variable "github_owner" {
  description = "GitHub repository owner"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
}

variable "github_environment" {
  description = "GitHub environment name"
  type        = string
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDR ranges allowed to access the Kubernetes API server."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  description = "EC2 instance types for the worker nodes."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "common_tags" {
  description = "Tags applied to resources that support tags"
  type        = map(string)
  default     = {}
}


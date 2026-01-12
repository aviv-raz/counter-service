variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "state_bucket_name" {
  description = "S3 bucket name for Terraform remote state"
  type        = string
}

variable "common_tags" {
  description = "Tags applied to resources that support tags"
  type        = map(string)
  default     = {}
}


variable "account_id" {
  type        = string
  description = "AWS account ID to allow for this prereqs run."
}

variable "region" {
  type        = string
  description = "AWS region for prereqs."
}

variable "cluster_name" {
  type        = string
  description = "Cluster name for tagging and resource naming."
}

variable "env" {
  type        = string
  description = "Environment name for tagging."
}

variable "base_domain" {
  type        = string
  description = "Base DNS domain for the cluster."
}

variable "hosted_zone_id" {
  type        = string
  description = "Optional Route53 hosted zone ID to use instead of creating one."
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Extra tags to apply to resources."
  default     = {}
}

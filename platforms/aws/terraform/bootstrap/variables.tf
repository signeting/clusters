variable "account_id" {
  type        = string
  description = "AWS account ID to allow for this bootstrap run."
}

variable "region" {
  type        = string
  description = "AWS region for the state bucket."
}

variable "bucket_name" {
  type        = string
  description = "Name of the S3 bucket to store Terraform state."
}

variable "tags" {
  type        = map(string)
  description = "Extra tags to apply to the bucket."
  default     = {}
}

output "bucket_name" {
  description = "Terraform state bucket name."
  value       = aws_s3_bucket.state.bucket
}

output "bucket_region" {
  description = "AWS region of the state bucket."
  value       = var.region
}

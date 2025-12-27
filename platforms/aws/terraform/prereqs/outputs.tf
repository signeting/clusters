output "hosted_zone_id" {
  description = "Route53 hosted zone ID for the cluster."
  value = local.using_existing_zone ? data.aws_route53_zone.existing[0].zone_id : aws_route53_zone.primary[0].zone_id
}

output "name_servers" {
  description = "Name servers for the hosted zone."
  value = local.using_existing_zone ? data.aws_route53_zone.existing[0].name_servers : aws_route53_zone.primary[0].name_servers
}

output "provisioner_role_arn" {
  description = "IAM role ARN for cluster provisioning."
  value       = aws_iam_role.provisioner.arn
}

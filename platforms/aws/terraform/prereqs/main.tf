locals {
  using_existing_zone = var.hosted_zone_id != ""
  tags = merge(
    {
      "managed-by" = "clusters"
      "cluster"    = var.cluster_name
      "env"        = var.env
    },
    var.tags
  )
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = local.tags
  }
}

resource "aws_route53_zone" "primary" {
  count = local.using_existing_zone ? 0 : 1

  name          = var.base_domain
  force_destroy = false
}

data "aws_route53_zone" "existing" {
  count = local.using_existing_zone ? 1 : 0

  zone_id = var.hosted_zone_id
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
  }
}

resource "aws_iam_role" "provisioner" {
  name               = "signet-${var.cluster_name}-provisioner"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachment" "provisioner_admin" {
  role       = aws_iam_role.provisioner.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

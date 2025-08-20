data "aws_route53_zone" "rockymtnwoods" {
  name         = "rockymtnwoods.com."
}

data "aws_acm_certificate" "rockymtnwoods_amazon_issued" {
  domain      = "rockymtnwoods.com"
  types       = ["AMAZON_ISSUED"]
  most_recent = true
}

module "acm" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 4.0"

  domain_name  = "rockymtnwoods.com"
  zone_id      = data.aws_route53_zone.rockymtnwoods.zone_id

  validation_method = "DNS"

  subject_alternative_names = [
    "*.rockymtnwoods.com",
  ]

  wait_for_validation = true

  tags = {
    Name = "rockymtnwoods.com"
    Managed_by = "Terraform"
  }
}
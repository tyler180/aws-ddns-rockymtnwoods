# output "acm_certificate" {
#     value = data.aws_acm_certificate.rockymtnwoods_amazon_issued.certificate
# }

output "acm_certificate_chain" {
  value = data.aws_acm_certificate.rockymtnwoods_amazon_issued.certificate_chain
}
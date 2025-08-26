# Variables you’ll pass in from your setup
variable "rolesanywhere_trust_anchor_arn" {
  type        = string
  default     = "arn:aws:rolesanywhere:us-west-2:138013422358:trust-anchor/697af620-f2c7-45a9-aa6d-2fd300b4670c"
  description = "ARN of the Roles Anywhere trust anchor created from rootCA.crt"
}

variable "nas_cert_cn" {
  type        = string
  default     = "synology-nas"
  description = "Common Name (CN) used in the NAS client certificate"
}

resource "aws_iam_role" "nas_rolesanywhere" {
  name = "ddns-nas-rolesanywhere"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "rolesanywhere.amazonaws.com"
        },
        Action = [
          "sts:AssumeRole",
          "sts:TagSession",
          "sts:SetSourceIdentity"
        ],
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = var.rolesanywhere_trust_anchor_arn
          },
          StringEquals = {
            "aws:PrincipalTag/x509Subject/CN" = var.nas_cert_cn
          }
        }
      }
    ]
  })
}
# IAM role the Synology will assume via Roles Anywhere
# resource "aws_iam_role" "nas_rolesanywhere" {
#   name = "ddns-nas-rolesanywhere"

#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Effect    = "Allow"
#         Principal = { Service = "rolesanywhere.amazonaws.com" }
#         Action    = "sts:AssumeRole"
#         Condition = {
#           StringEquals = {
#             # TODO: paste your Roles Anywhere profile ARN here after you create it
#             "aws:PrincipalTag/rolesanywhere.amazonaws.com/ProfileArn" = "arn:aws:rolesanywhere:us-west-2:138013422358:profile/ed2eab48-23b5-4c85-97b4-83018af59d54"
#           }
#         }
#       }
#     ]
#   })
# }

# Policy: allow NAS only to read the DDNS secret
data "aws_iam_policy_document" "nas_secrets_read" {
  statement {
    sid     = "SecretsRead"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.ddns_token.arn,
      "${aws_secretsmanager_secret.ddns_token.arn}-*"
    ]
  }
}

resource "aws_iam_policy" "nas_secrets_read" {
  name   = "ddns-nas-secrets-read"
  policy = data.aws_iam_policy_document.nas_secrets_read.json
}

resource "aws_iam_role_policy_attachment" "nas_attach" {
  role       = aws_iam_role.nas_rolesanywhere.name
  policy_arn = aws_iam_policy.nas_secrets_read.arn
}

output "nas_rolesanywhere_role_arn" {
  value       = aws_iam_role.nas_rolesanywhere.arn
  description = "IAM role for Synology NAS via Roles Anywhere"
}


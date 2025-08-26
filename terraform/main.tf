terraform {
  required_version = ">= 1.0.0"

  backend "s3" {
    region         = "us-west-2"
    bucket         = "rockymtnwoods-tf-backends"
    key            = "route53/terraform.tfstate"
    encrypt        = "true"
    dynamodb_table = "terraform-lock-table"
  }
}

# ---------- Build all zips via build.sh ----------
# resource "null_resource" "build_all" {
#   triggers = {
#     ddns_src = filesha256("${var.src_dir}/main.go")
#     auth_src = filesha256("${var.src_dir}/authorizer/main.go")
#     rot_src  = fileexists("${var.src_dir}/rotator/main.go") ? filesha256("${var.src_dir}/rotator/main.go") : "absent"
#     go_mod   = filesha256("${var.src_dir}/go.mod")
#     go_sum   = fileexists("${var.src_dir}/go.sum") ? filesha256("${var.src_dir}/go.sum") : "absent"
#     runtime  = var.lambda_runtime
#     arch     = var.lambda_arch
#     use_rot  = var.enable_rotator ? "on" : "off"
#   }
#   provisioner "local-exec" {
#     working_dir = path.module
#     command     = <<-EOF
#       set -euo pipefail
#       ../build.sh --runtime "${var.lambda_runtime}" --arch "${var.lambda_arch}" --rotator "${var.enable_rotator ? "on" : "off"}"
#     EOF
#   }
# }

resource "null_resource" "build_all" {
  triggers = {
    ddns_src = filesha256(abspath("${path.module}/../main.go"))
    auth_src = filesha256(abspath("${path.module}/../authorizer/main.go"))
    rot_src  = fileexists(abspath("${path.module}/../rotator/main.go")) ? filesha256(abspath("${path.module}/../rotator/main.go")) : "absent"

    ddns_mod = filesha256(abspath("${path.module}/../go.mod"))
    ddns_sum = fileexists(abspath("${path.module}/../go.sum")) ? filesha256(abspath("${path.module}/../go.sum")) : "absent"
    auth_mod = filesha256(abspath("${path.module}/../authorizer/go.mod"))
    auth_sum = fileexists(abspath("${path.module}/../authorizer/go.sum")) ? filesha256(abspath("${path.module}/../authorizer/go.sum")) : "absent"
    rot_mod  = fileexists(abspath("${path.module}/../rotator/go.mod")) ? filesha256(abspath("${path.module}/../rotator/go.mod")) : "absent"
    rot_sum  = fileexists(abspath("${path.module}/../rotator/go.sum")) ? filesha256(abspath("${path.module}/../rotator/go.sum")) : "absent"

    runtime = var.lambda_runtime
    arch    = var.lambda_arch
    rotator = var.enable_rotator ? "on" : "off"
  }

  provisioner "local-exec" {
    # 👇 run from repo root (one level up from terraform/)
    working_dir = abspath("${path.module}/..")
    command     = <<-EOF
      set -euo pipefail
      ./build.sh --runtime "${var.lambda_runtime}" --arch "${var.lambda_arch}" --rotator "${var.enable_rotator ? "on" : "off"}"
    EOF
  }
}

# Wrap each zip so we can hash + upload cleanly
data "archive_file" "ddns_zip" {
  type        = "zip"
  source_file = abspath("${path.module}/../function.zip")
  output_path = "${path.module}/.ddns-upload.zip"
  depends_on  = [null_resource.build_all]
}

data "archive_file" "authorizer_zip" {
  type        = "zip"
  source_file = abspath("${path.module}/../authorizer.zip")
  output_path = "${path.module}/.authorizer-upload.zip"
  depends_on  = [null_resource.build_all]
}

data "archive_file" "rotator_zip" {
  count       = var.enable_rotator ? 1 : 0
  type        = "zip"
  source_file = abspath("${path.module}/../rotator.zip")
  output_path = "${path.module}/.rotator-upload.zip"
  depends_on  = [null_resource.build_all]
}

# ---------- IAM for DDNS Lambda ----------
data "aws_iam_policy_document" "assume_lambda" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "ddns_role" {
  name               = "ddns-lambda-role-http"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}
data "aws_iam_policy_document" "ddns_policy" {
  statement {
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.hosted_zone_id}"]
  }
  statement {
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
}
resource "aws_iam_policy" "ddns_policy" {
  name   = "ddns-lambda-policy-http"
  policy = data.aws_iam_policy_document.ddns_policy.json
}
resource "aws_iam_role_policy_attachment" "ddns_attach" {
  role       = aws_iam_role.ddns_role.name
  policy_arn = aws_iam_policy.ddns_policy.arn
}

# ---------- Rotator (optional) ----------
resource "aws_iam_role" "rot_role" {
  count              = var.enable_rotator ? 1 : 0
  name               = "ddns-rotator-role"
  assume_role_policy = data.aws_iam_policy_document.rot_assume.json
}
# Permissions for logging + Secrets Manager write
data "aws_iam_policy_document" "rot_policy" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
    ]
    resources = [
      aws_secretsmanager_secret.ddns_token.arn,
      "${aws_secretsmanager_secret.ddns_token.arn}-*"
    ]
  }
}

resource "aws_iam_policy" "rot_policy" {
  count  = var.enable_rotator ? 1 : 0
  name   = "ddns-rotator-policy"
  policy = data.aws_iam_policy_document.rot_policy.json
}

resource "aws_iam_role_policy_attachment" "rot_attach" {
  count      = var.enable_rotator ? 1 : 0
  role       = aws_iam_role.rot_role[0].name
  policy_arn = aws_iam_policy.rot_policy[0].arn
}

data "aws_iam_policy_document" "rot_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}
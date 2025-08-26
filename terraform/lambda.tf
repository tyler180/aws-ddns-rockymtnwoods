terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.50" }
    archive = { source = "hashicorp/archive", version = "~> 2.5" }
  }
}

data "aws_caller_identity" "current" {}

# --- Build & Package (automatic) -------------------------------------------
# Cleans and builds your Go binary into ../dist/, then zips it to ../function.zip
# resource "null_resource" "build_lambda" {
#   triggers = {
#     # re-build when these change
#     src_hash    = filesha256("${var.src_dir}/main.go")
#     go_mod_hash = filesha256("${var.src_dir}/go.mod")
#     runtime     = var.lambda_runtime
#   }

#   provisioner "local-exec" {
#     working_dir = var.src_dir
#     command     = <<-EOF
#       set -euo pipefail
#       rm -rf dist function.zip
#       mkdir -p dist
#       if [ "${var.lambda_runtime}" = "go1.x" ]; then
#         GOOS=linux GOARCH=amd64 go build -o dist/main main.go
#       else
#         GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o dist/bootstrap main.go
#       fi
#       (cd dist && zip -qr ../function.zip .)
#     EOF
#   }
# }

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${var.src_dir}/function.zip"
  output_path = "${path.module}/.tf-upload.zip"
  depends_on  = [null_resource.build_all]
}

# --- IAM -------------------------------------------------------------------
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "ddns-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "policy" {
  statement {
    sid       = "Route53Change"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.hosted_zone_id}"]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "lambda" {
  name   = "ddns-lambda-policy"
  policy = data.aws_iam_policy_document.policy.json
}

resource "aws_iam_role_policy_attachment" "attach" {
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda.arn
}

resource "aws_lambda_function" "rotator" {
  count            = var.enable_rotator ? 1 : 0
  function_name    = "ddns-token-rotator"
  filename         = data.archive_file.rotator_zip[0].output_path
  source_code_hash = filebase64sha256(data.archive_file.rotator_zip[0].output_path)
  # source_code_hash = data.archive_file.rotator_zip[0].output_base64sha256

  runtime     = "provided.al2023"
  handler     = "bootstrap"
  role        = aws_iam_role.rot_role[0].arn
  memory_size = 128
  timeout     = 5
  environment {
    variables = {
      DDNS_SHARED_TOKEN_SECRET_ARN = aws_secretsmanager_secret.ddns_token.arn
    }
  }
  depends_on = [aws_iam_role_policy_attachment.rot_attach]
}
resource "aws_cloudwatch_event_rule" "rotate_daily" {
  count               = var.enable_rotator ? 1 : 0
  name                = "ddns-token-rotate-daily"
  schedule_expression = var.rotation_cron
}
resource "aws_cloudwatch_event_target" "rotate_target" {
  count     = var.enable_rotator ? 1 : 0
  rule      = aws_cloudwatch_event_rule.rotate_daily[0].name
  target_id = "ddns-rotator"
  arn       = aws_lambda_function.rotator[0].arn
}
resource "aws_lambda_permission" "allow_events" {
  count         = var.enable_rotator ? 1 : 0
  statement_id  = "AllowEventsToInvokeRotator"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotator[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.rotate_daily[0].arn
}

resource "aws_lambda_permission" "allow_secretsmanager_invoke_rotator" {
  statement_id  = "AllowSecretsManagerInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotator[0].function_name
  principal     = "secretsmanager.amazonaws.com"
  source_arn    = aws_secretsmanager_secret.ddns_token.arn
}

# ---------- Authorizer Lambda ----------
# resource "aws_iam_role" "auth_role" {
#   name               = "ddns-authorizer-role"
#   assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
# }
# resource "aws_iam_policy" "auth_policy" {
#   name = "ddns-authorizer-policy"
#   policy = jsonencode({
#     Version = "2012-10-17",
#     Statement = [
#       { Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = "*" },
#       { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = aws_secretsmanager_secret.ddns_token.arn }
#     ]
#   })
# }
# resource "aws_iam_role_policy_attachment" "auth_attach" {
#   role       = aws_iam_role.auth_role.name
#   policy_arn = aws_iam_policy.auth_policy.arn
# }

# --- Assume-role trust (Lambda) ---
data "aws_iam_policy_document" "auth_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "auth_role" {
  name               = "ddns-authorizer-role"
  assume_role_policy = data.aws_iam_policy_document.auth_assume.json
}

# --- Inline policy: Logs + read the ddns/token secret ---
data "aws_iam_policy_document" "auth_policy" {
  # CloudWatch Logs (standard Lambda logging perms)
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["*"]
  }

  # Read the shared token from Secrets Manager
  statement {
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.ddns_token.arn,
      "${aws_secretsmanager_secret.ddns_token.arn}-*" # allow specific versions
    ]
  }
}

resource "aws_iam_policy" "auth_policy" {
  name   = "ddns-authorizer-policy"
  policy = data.aws_iam_policy_document.auth_policy.json
}

resource "aws_iam_role_policy_attachment" "auth_attach" {
  role       = aws_iam_role.auth_role.name
  policy_arn = aws_iam_policy.auth_policy.arn
}

resource "aws_lambda_function" "authorizer" {
  function_name    = "ddns-http-authorizer"
  filename         = data.archive_file.authorizer_zip.output_path
  source_code_hash = data.archive_file.authorizer_zip.output_base64sha256

  runtime     = "provided.al2023"
  handler     = "bootstrap"
  role        = aws_iam_role.auth_role.arn
  memory_size = 128
  timeout     = 3

  environment {
    variables = {
      DDNS_SHARED_TOKEN_SECRET_ARN = aws_secretsmanager_secret.ddns_token.arn
    }
  }

  depends_on = [aws_iam_role_policy_attachment.auth_attach]
}

# ---------- DDNS Lambda ----------
resource "aws_lambda_function" "ddns" {
  function_name    = "ddns-route53"
  filename         = data.archive_file.ddns_zip.output_path
  source_code_hash = filebase64sha256(data.archive_file.ddns_zip.output_path)
  # source_code_hash = data.archive_file.ddns_zip.output_base64sha256

  runtime     = var.lambda_runtime
  handler     = var.lambda_runtime == "go1.x" ? "main" : "bootstrap"
  role        = aws_iam_role.ddns_role.arn
  memory_size = 128
  timeout     = 5

  environment {
    variables = {
      HOSTED_ZONE_ID               = var.hosted_zone_id
      RECORD_NAME                  = var.record_name
      TTL                          = tostring(var.ttl)
      DDNS_SHARED_TOKEN_SECRET_ARN = aws_secretsmanager_secret.ddns_token.arn
    }
  }

  depends_on = [aws_iam_role_policy_attachment.ddns_attach]
}

data "aws_iam_policy_document" "ddns_secret_read" {
  statement {
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.ddns_token.arn,
      "${aws_secretsmanager_secret.ddns_token.arn}-*"
    ]
  }
}
resource "aws_iam_policy" "ddns_secret_read" {
  name   = "ddns-read-ddns-token"
  policy = data.aws_iam_policy_document.ddns_secret_read.json
}
resource "aws_iam_role_policy_attachment" "ddns_secret_read_attach" {
  role       = aws_iam_role.ddns_role.name # your ddns lambda role
  policy_arn = aws_iam_policy.ddns_secret_read.arn
}

# --- HTTP API (no usage plan) ----------------------------------------------
# resource "aws_apigatewayv2_api" "http" {
#   name          = "ddns-http-api"
#   protocol_type = "HTTP"
# }

# resource "aws_apigatewayv2_integration" "lambda" {
#   api_id                 = aws_apigatewayv2_api.http.id
#   integration_type       = "AWS_PROXY"
#   integration_uri        = aws_lambda_function.ddns.arn
#   integration_method     = "POST"
#   payload_format_version = "2.0"
# }

# ---------- HTTP API + Authorizer hookup ----------
resource "aws_apigatewayv2_api" "http" {
  name          = "ddns-http"
  protocol_type = "HTTP"
  description   = "DDNS updater API"
}
# resource "aws_apigatewayv2_integration" "ddns_lambda" {
#   api_id                 = aws_apigatewayv2_api.http.id
#   integration_type       = "AWS_PROXY"
#   integration_uri        = aws_lambda_function.ddns.arn
#   integration_method     = "POST"
#   payload_format_version = "2.0"
# }
resource "aws_apigatewayv2_integration" "ddns" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = "arn:aws:apigateway:${var.region}:lambda:path/2015-03-31/functions/${aws_lambda_function.ddns.arn}/invocations"
  payload_format_version = "2.0"
}

# resource "aws_apigatewayv2_authorizer" "req_auth" {
#   api_id          = aws_apigatewayv2_api.http.id
#   name            = "ddns-token-authorizer"
#   authorizer_type = "REQUEST"

#   # Critical for simple isAuthorized responses:
#   authorizer_payload_format_version = "2.0"
#   enable_simple_responses           = true

#   authorizer_uri = "arn:aws:apigateway:${var.region}:lambda:path/2015-03-31/functions/${aws_lambda_function.authorizer.arn}/invocations"

#   identity_sources = [
#     "$request.header.X-Token",
#     "$request.querystring.token",
#   ]
# }

resource "aws_apigatewayv2_authorizer" "req_auth" {
  api_id          = aws_apigatewayv2_api.http.id
  name            = "ddns-token-authorizer"
  authorizer_type = "REQUEST"

  # HTTP API v2 authorizers + simple response
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true

  # Disable cache during debugging (prevents stale denies)
  authorizer_result_ttl_in_seconds = 0

  authorizer_uri = "arn:aws:apigateway:${var.region}:lambda:path/2015-03-31/functions/${aws_lambda_function.authorizer.arn}/invocations"

  # IMPORTANT: use lower-case header name; HTTP header lookup is case-insensitive,
  # but the identity *source* key matching is picky and lower-case avoids issues.
  identity_sources = [
    "$request.header.x-token",
    "$request.querystring.token",
  ]
}

resource "aws_apigatewayv2_route" "ddns" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "ANY /ddns"
  target    = "integrations/${aws_apigatewayv2_integration.ddns.id}"

  authorization_type = "NONE"
  # no authorizer_id
}
resource "aws_cloudwatch_log_group" "apigw_access" {
  name              = "/aws/apigw/ddns-http-access"
  retention_in_days = 7
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw_access.arn
    format = jsonencode({
      requestId       = "$context.requestId",
      routeKey        = "$context.routeKey",
      status          = "$context.status",
      authorizerError = "$context.authorizer.error",
      authorizerValue = "$context.authorizer.principalId"
    })
  }
}
resource "aws_lambda_permission" "allow_apigw_invoke_ddns" {
  statement_id  = "AllowAPIGWInvokeDDNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ddns.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "arn:aws:execute-api:${var.region}:${data.aws_caller_identity.current.account_id}:${aws_apigatewayv2_api.http.id}/*/*/ddns"
}

# Who am I
data "aws_caller_identity" "me" {}

# BROAD permission so HTTP API can invoke the authorizer in all cases
resource "aws_lambda_permission" "allow_apigw_invoke_authorizer_wide" {
  statement_id  = "AllowAPIGWInvokeAuthorizerWide"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"

  # Allow ANY call from this API (stage/route/authorizer variations)
  source_arn = "arn:aws:execute-api:${var.region}:${data.aws_caller_identity.me.account_id}:${aws_apigatewayv2_api.http.id}/*"
}

# resource "aws_lambda_permission" "allow_apigw_invoke_authorizer" {
#   statement_id  = "AllowAPIGWInvokeAuthorizer"
#   action        = "lambda:InvokeFunction"
#   function_name = aws_lambda_function.authorizer.function_name
#   principal     = "apigateway.amazonaws.com"
#   # Permission scoped to this API's authorizer
#   source_arn = "${aws_apigatewayv2_api.http.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.req_auth.id}"
# }

output "ddns_url" {
  value = "${aws_apigatewayv2_api.http.api_endpoint}/ddns"
}

# ---------------------------------------------------------------------------
# Build & Package (calls ../build.sh)
# ---------------------------------------------------------------------------
# resource "null_resource" "build_lambda" {
#   triggers = {
#     # Rebuild when these change:
#     src_hash    = filesha256("${var.src_dir}/main.go")
#     go_mod_hash = filesha256("${var.src_dir}/go.mod")
#     # go_sum_hash = filesha256("${var.src_dir}/go.sum")
#     runtime = var.lambda_runtime
#     arch    = var.lambda_arch
#     out_zip = var.out_zip
#   }

#   provisioner "local-exec" {
#     working_dir = path.module # so ../build.sh resolves from terraform/
#     command     = <<-EOF
#       set -euo pipefail
#       ../build.sh --runtime "${var.lambda_runtime}" --arch "${var.lambda_arch}" --src "${var.src_dir}" --out "${var.out_zip}"
#     EOF
#   }
# }
output "api_id" {
  value       = aws_apigatewayv2_api.http.id
  description = "HTTP API ID"
}
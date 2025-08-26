# --- Secret to hold the shared token ---------------------------------------
resource "aws_secretsmanager_secret" "ddns_token" {
  name        = "ddns/token"
  description = "Shared token for DDNS HTTP API authorizer"
}

# Seed the first value (generate a strong random string once)
resource "random_password" "seed" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret_version" "ddns_token_v1" {
  secret_id     = aws_secretsmanager_secret.ddns_token.id
  secret_string = random_password.seed.result
}

resource "aws_secretsmanager_secret_rotation" "ddns_token" {
  secret_id           = aws_secretsmanager_secret.ddns_token.id
  rotation_lambda_arn = aws_lambda_function.rotator[0].arn

  rotation_rules {
    automatically_after_days = 30
  }
}

output "secret_arn" { value = aws_secretsmanager_secret.ddns_token.arn }
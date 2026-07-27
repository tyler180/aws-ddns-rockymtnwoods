# AWS DDNS for rockymtnwoods.com

Dynamic DNS updater for Route 53, implemented with AWS Lambda, API Gateway HTTP API, Secrets Manager, and Terraform.

The main Lambda accepts an HTTP request, authenticates it with a shared token, detects the caller's source IP address, and upserts the configured Route 53 record as either an `A` or `AAAA` record. This is intended for clients such as a home router, NAS, or scheduled job that need to keep a DNS record pointed at a changing public IP address.

## What This Deploys

- `ddns-route53`: Lambda function that updates the Route 53 record.
- `ddns-http`: API Gateway HTTP API with an `/ddns` route.
- `ddns/token`: Secrets Manager secret containing the shared update token.
- `ddns-token-rotator`: Optional Lambda that rotates the shared token.
- `ddns-http-authorizer`: Token authorizer Lambda. The Terraform currently creates this authorizer, but the `/ddns` route is configured with `authorization_type = "NONE"`; the DDNS Lambda itself still enforces the token.
- IAM roles and policies for Lambda execution, Route 53 updates, secret access, logging, and AWS Roles Anywhere access for a NAS.
- ACM resources for `rockymtnwoods.com` and `*.rockymtnwoods.com`.

## Repository Layout

```text
.
|-- main.go                 # DDNS updater Lambda
|-- build.sh                # Builds Lambda zip packages
|-- authorizer/
|   `-- main.go             # API Gateway request authorizer Lambda
|-- rotator/
|   `-- main.go             # Secrets Manager token rotator Lambda
`-- terraform/
    |-- main.tf             # Backend and build packaging
    |-- lambda.tf           # Lambda, API Gateway, IAM, outputs
    |-- route53.tf          # Route 53/ACM resources
    |-- secretsmanager.tf   # Shared token secret and rotation
    |-- iam-nas.tf          # Roles Anywhere access for NAS secret reads
    `-- variables.tf        # Terraform inputs
```

## Prerequisites

- Go 1.24.x
- Terraform 1.0+
- `zip`
- AWS credentials with permission to assume the Terraform role configured in `terraform/provider.tf`
- Access to the S3 backend configured in `terraform/main.tf`
- An existing Route 53 hosted zone for `rockymtnwoods.com`

This Terraform is currently environment-specific. It assumes:

- AWS region `us-west-2`
- AWS account `138013422358`
- Terraform state bucket `rockymtnwoods-tf-backends`
- DynamoDB lock table `terraform-lock-table`
- Terraform role `arn:aws:iam::138013422358:role/terraform`
- Hosted zone defaults for `rockymtnwoods.com.`

Update `terraform/provider.tf`, `terraform/main.tf`, and the defaults in `terraform/variables.tf` before reusing this in another AWS account or domain.

## Build

Build all Lambda packages from the repository root:

```bash
./build.sh
```

By default this builds for the Lambda custom runtime `provided.al2023` on `amd64` and creates:

- `function.zip`
- `authorizer.zip`
- `rotator.zip`

Optional flags:

```bash
./build.sh --runtime provided.al2023 --arch amd64 --rotator on
./build.sh --runtime provided.al2023 --arch arm64 --rotator on
./build.sh --runtime go1.x --arch amd64 --rotator off
```

## Deploy

Terraform runs `./build.sh` automatically through a `null_resource`, so a normal apply is enough:

```bash
cd terraform
terraform init
terraform plan -var 'shared_token=initial-token-value'
terraform apply -var 'shared_token=initial-token-value'
```

The `shared_token` variable seeds the first Secrets Manager secret value. It is marked sensitive, but it is still part of Terraform state. Prefer passing it through your shell, CI secret store, or a local `terraform.tfvars` that is not committed.

Useful variables:

```hcl
region          = "us-west-2"
hosted_zone_id  = "Z029653525HA7L1SB7RB6"
record_name     = "rockymtnwoods.com."
ttl             = 60
lambda_runtime  = "provided.al2023"
lambda_arch     = "amd64"
enable_rotator  = true
rotation_cron   = "cron(0 3 * * ? *)"
```

After apply, Terraform outputs `ddns_url`, for example:

```bash
terraform output -raw ddns_url
```

## Use the DDNS Endpoint

Get the current shared token from Secrets Manager:

```bash
aws secretsmanager get-secret-value \
  --secret-id ddns/token \
  --query SecretString \
  --output text
```

Call the endpoint with the token in the `x-token` header:

```bash
curl -sS \
  -H "x-token: $DDNS_TOKEN" \
  "$(terraform -chdir=terraform output -raw ddns_url)"
```

Or pass the token as a query parameter:

```bash
curl -sS "$(terraform -chdir=terraform output -raw ddns_url)?token=$DDNS_TOKEN"
```

Example response when the record changes:

```json
{
  "status": "updated",
  "record": "rockymtnwoods.com.",
  "type": "A",
  "old": "203.0.113.10",
  "new": "203.0.113.25",
  "ttl": 60
}
```

If the caller IP already matches Route 53, the function returns `status: "nochange"`.

## Runtime Behavior

The updater determines the caller IP from API Gateway's `requestContext.http.sourceIp`, then falls back to the first IP in `x-forwarded-for`. IPv4 callers update an `A` record; IPv6 callers update an `AAAA` record.

The shared token is read from Secrets Manager using `DDNS_SHARED_TOKEN_SECRET_ARN` and cached in the Lambda execution environment for 30 seconds. Requests may provide the token through either:

- `x-token` header
- `token` query string parameter

## Token Rotation

The rotator Lambda generates a new URL-safe random token and writes it to the same Secrets Manager secret. Terraform enables two rotation mechanisms by default:

- A CloudWatch Events schedule from `rotation_cron`, defaulting to daily at 03:00 UTC.
- Secrets Manager rotation rules with `automatically_after_days = 30`.

Clients that call the DDNS endpoint need a way to refresh the token after rotation. The NAS IAM role in `terraform/iam-nas.tf` is configured to allow reading `ddns/token` through AWS Roles Anywhere.

## License

This project is licensed under the terms in [LICENSE](LICENSE).

variable "region" {
  type    = string
  default = "us-west-2"
}
variable "hosted_zone_id" {
  type    = string
  default = "Z029653525HA7L1SB7RB6" # e.g. "Z029653525HA7L1SB7RB6" for rockymtnwoods.com
}
variable "record_name" {
  type    = string
  default = "rockymtnwoods.com." # e.g. "home.example.com."
}                                # e.g. "home.example.com."
variable "shared_token" {
  type      = string
  sensitive = true
}
variable "ttl" {
  type    = number
  default = 60
}

# Path to the Go sources (relative to repo root)
variable "src_dir" {
  type    = string
  default = ".."
}

# Build target: "go1.x" -> dist/main, or "provided.al2023" -> dist/bootstrap
variable "lambda_runtime" {
  type    = string
  default = "provided.al2023"
}

# Build/run config
variable "lambda_arch" {
  type    = string
  default = "amd64"
} # or "arm64"
variable "out_zip" {
  type    = string
  default = "../function.zip"
} # where build.sh writes the zip

# Rotation controls
variable "enable_rotator" {
  type    = bool
  default = true
}
# UTC: rotate daily 03:00 by default
variable "rotation_cron" {
  type    = string
  default = "cron(0 3 * * ? *)"
}
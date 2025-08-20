terraform {
  required_version = ">= 1.0.0"

  backend "s3" {
    region  = "us-west-2"
    bucket  = "rockymtnwoods-tf-backends"
    key     = "route53/terraform.tfstate"
    encrypt = "true"
    dynamodb_table = "terraform-lock-table"
  }
}
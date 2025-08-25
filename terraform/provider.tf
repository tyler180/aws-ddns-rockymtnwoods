provider "aws" {
  region  = "us-west-2"
  assume_role {
    role_arn = "arn:aws:iam::138013422358:role/terraform"
  }
}
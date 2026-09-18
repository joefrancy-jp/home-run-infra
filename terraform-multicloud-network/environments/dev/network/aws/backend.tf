# Remote state in an S3 bucket.
#
# "key" is NOT written here on purpose. deploy.sh passes it at init time as:
#   <resource>/<env>-home-run-aws.tfstate   (e.g. network/dev-home-run-aws.tfstate)
# Terraform does not allow variables inside a backend block, so this is the
# standard way to change the state file name per environment.
terraform {
  backend "s3" {
    bucket       = "CHANGE-ME-tf-state-bucket"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true # native S3 locking, no DynamoDB table needed
  }
}

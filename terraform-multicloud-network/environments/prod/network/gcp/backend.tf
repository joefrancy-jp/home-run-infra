# Remote state in a GCS bucket.
#
# "prefix" is passed by deploy.sh at init time as:
#   <resource>/<env>-home-run-gcp   (e.g. network/dev-home-run-gcp)
# GCS always names the file itself "default.tfstate", so the object becomes:
#   gs://<bucket>/network/dev-home-run-gcp/default.tfstate
# Locking is built in.
terraform {
  backend "gcs" {
    bucket = "CHANGE-ME-tf-state-bucket"
  }
}

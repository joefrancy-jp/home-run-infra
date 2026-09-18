mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/test-role" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/test-policy" }
  }
  mock_resource "aws_launch_template" {
    defaults = { latest_version = 1, id = "lt-0123456789abcdef0" }
  }
  override_data {
    target = module.network.data.aws_availability_zones.available
    values = { names = ["ap-south-1a", "ap-south-1b", "ap-south-1c"] }
  }
  override_data {
    target = module.platform.data.aws_partition.current
    values = { partition = "aws" }
  }
  override_data {
    target = module.platform.data.aws_ami.ubuntu
    values = { id = "ami-0123456789abcdef0" }
  }
}
run "private_cluster_contract" {
  command = apply
  variables {
    cluster_admin_identities = ["arn:aws:iam::123456789012:role/ClusterAdmin"]
    vpn_ssh_public_key       = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINBg3Gu34Yb4Me8gIrCiAZirWX/93S96oBoWYitg4phH"
  }
  assert {
    condition     = module.platform.security.private_api
    error_message = "The Kubernetes API must remain private."
  }
  assert {
    condition     = module.platform.security.ha_workers
    error_message = "Workers must span three zones with HA enabled."
  }
  assert {
    condition     = !module.platform.security.vpn_public_ssh
    error_message = "OpenVPN must not expose public SSH."
  }
}

mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      name  = "projects/test-project/serviceAccounts/test-account@test-project.iam.gserviceaccount.com"
      email = "test-account@test-project.iam.gserviceaccount.com"
    }
  }
  override_data {
    target = module.platform.data.google_compute_zones.available
    values = { names = ["asia-south1-a", "asia-south1-b", "asia-south1-c"] }
  }
}
run "private_cluster_contract" {
  command = apply
  variables {
    cluster_admin_identities = ["group:admins@example.com"]
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

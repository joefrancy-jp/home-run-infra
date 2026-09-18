mock_provider "azurerm" {
  override_data {
    target = data.azurerm_client_config.current
    values = { tenant_id = "11111111-1111-1111-1111-111111111111" }
  }
}
run "private_cluster_contract" {
  command = plan
  variables {
    cluster_admin_identities = ["22222222-2222-2222-2222-222222222222"]
    vpn_ssh_public_key       = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDlTybDmRdBYod4QkYWuBRhRpZxxxMbLf2n8cNaO6s2WTbWTDzWO+dX8MqN+DGz+lQJCXcZZIdfPz3U5qXoHm+y5L1t+GTKF+6zHUZKkCRpmTN0LOxySvzwrsuMZReGzUYtCUM3KFw8c0ubbqHj10MNomfgmhy1X9rHvDBnbswQwc7W2y9Hly0JV3GDGmaqHJqeByirFAaVwOUdVxeXci1t4qWuvMtLxNaq70oSOPBbG/zlKRKWPln2peFVZ2lLLu1dgZgc3SOIhwJbj9yvSq25W5aRxLzr7zGqf93+OH86D+Q5vI2Uk7IDxk5JIbwA/vd0tik/NWrQwiwnGNSRrpn3"
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

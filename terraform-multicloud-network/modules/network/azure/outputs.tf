output "network_id" {
  value = azurerm_virtual_network.this.id
}

output "vnet_name" { value = azurerm_virtual_network.this.name }

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "public_subnet_ids" {
  value = azurerm_subnet.public[*].id
}

output "private_subnet_ids" {
  value = azurerm_subnet.private[*].id
}

output "db_subnet_ids" {
  value = azurerm_subnet.db[*].id
}

output "nat_public_ip" {
  value = azurerm_public_ip.nat.ip_address
}

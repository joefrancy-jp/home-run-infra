output "network_id" {
  value = module.network.network_id
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

output "db_subnet_ids" {
  value = module.network.db_subnet_ids
}

output "nat_public_ips" {
  value = module.network.nat_public_ips
}

output "db_subnet_group_name" {
  value = module.network.db_subnet_group_name
}

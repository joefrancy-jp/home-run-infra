output "network_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "db_subnet_ids" {
  value = aws_subnet.db[*].id
}

output "nat_public_ips" {
  value = aws_eip.nat[*].public_ip
}

output "db_subnet_group_name" {
  value = aws_db_subnet_group.this.name
}

output "network_id" {
  value = google_compute_network.this.id
}

output "public_subnet_ids" {
  value = google_compute_subnetwork.public[*].id
}

output "private_subnet_ids" {
  value = google_compute_subnetwork.private[*].id
}

output "db_subnet_ids" {
  value = google_compute_subnetwork.db[*].id
}

output "nat_name" {
  value = google_compute_router_nat.this.name
}

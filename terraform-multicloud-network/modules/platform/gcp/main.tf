data "google_compute_zones" "available" {
  project = var.project_id
  region  = var.region
  status  = "UP"
}
resource "google_project_service" "required" {
  for_each           = toset(["compute.googleapis.com", "container.googleapis.com", "iam.googleapis.com", "iap.googleapis.com", "oslogin.googleapis.com"])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
resource "google_service_account" "nodes" {
  project      = var.project_id
  account_id   = "${var.name}-nodes"
  display_name = "Private GKE node identity"
}
resource "google_project_iam_member" "nodes" {
  for_each = toset(["roles/container.defaultNodeServiceAccount", "roles/artifactregistry.reader"])
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.nodes.email}"
}
resource "google_project_iam_member" "admins" {
  for_each = var.cluster_admin_members
  project  = var.project_id
  role     = "roles/container.admin"
  member   = each.value
}
resource "google_container_cluster" "this" {
  project                  = var.project_id
  name                     = var.name
  location                 = var.region
  node_locations           = slice(data.google_compute_zones.available.names, 0, 3)
  network                  = var.network_id
  subnetwork               = var.private_subnet_ids[0]
  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = var.env == "prod"
  min_master_version       = var.kubernetes_version
  networking_mode          = "VPC_NATIVE"
  datapath_provider        = "LEGACY_DATAPATH"
  network_policy {
    enabled  = true
    provider = "CALICO"
  }
  addons_config {
    network_policy_config { disabled = false }
  }
  release_channel { channel = "REGULAR" }
  gateway_api_config { channel = "CHANNEL_STANDARD" }
  workload_identity_config { workload_pool = "${var.project_id}.svc.id.goog" }
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
    master_ipv4_cidr_block  = var.master_cidr
    master_global_access_config { enabled = true }
  }
  master_authorized_networks_config {
    private_endpoint_enforcement_enabled = true
    gcp_public_cidrs_access_enabled      = false
    cidr_blocks {
      cidr_block   = var.vpc_cidr
      display_name = "Private VPC including SNATed OpenVPN clients"
    }
  }
  control_plane_endpoints_config {
    dns_endpoint_config { allow_external_traffic = false }
  }
  master_auth {
    client_certificate_config { issue_client_certificate = false }
  }
  enable_shielded_nodes = true
  depends_on            = [google_project_service.required]
}
resource "google_container_node_pool" "this" {
  project        = var.project_id
  name           = "private"
  cluster        = google_container_cluster.this.name
  location       = var.region
  node_locations = slice(data.google_compute_zones.available.names, 0, 3)
  node_count     = 1
  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }
  management {
    auto_repair  = true
    auto_upgrade = true
  }
  node_config {
    machine_type    = "e2-standard-2"
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    tags            = ["${var.name}-nodes"]
    metadata        = { disable-legacy-endpoints = "true" }
    workload_metadata_config { mode = "GKE_METADATA" }
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
  depends_on = [google_project_iam_member.nodes]
}

resource "google_compute_firewall" "internal" {
  project       = var.project_id
  name          = "${var.name}-private-internal"
  network       = var.network_id
  direction     = "INGRESS"
  source_ranges = [var.vpc_cidr, var.pod_cidr, var.master_cidr]
  target_tags   = ["${var.name}-nodes", "${var.name}-vpn"]
  allow { protocol = "all" }
}
resource "google_compute_firewall" "load_balancer" {
  project       = var.project_id
  name          = "${var.name}-lb-to-gateway"
  network       = var.network_id
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22", cidrsubnet(var.vpc_cidr, 8, 30)]
  target_tags   = ["${var.name}-nodes"]
  allow {
    protocol = "tcp"
    ports    = ["8000"]
  }
}
resource "google_compute_subnetwork" "proxy" {
  project       = var.project_id
  name          = "${var.name}-proxy-only"
  region        = var.region
  network       = var.network_id
  ip_cidr_range = cidrsubnet(var.vpc_cidr, 8, 30)
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}
resource "google_compute_firewall" "vpn" {
  project       = var.project_id
  name          = "${var.name}-openvpn"
  network       = var.network_id
  source_ranges = var.vpn_source_cidrs
  target_tags   = ["${var.name}-vpn"]
  allow {
    protocol = "udp"
    ports    = ["1194"]
  }
}
# Initial client issuance uses IAM-authorized IAP/OS Login, never public SSH.
resource "google_compute_firewall" "vpn_management" {
  project       = var.project_id
  name          = "${var.name}-vpn-iap-management"
  network       = var.network_id
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["${var.name}-vpn"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
resource "google_service_account" "vpn" {
  project      = var.project_id
  account_id   = "${var.name}-vpn"
  display_name = "OpenVPN VM; no project roles"
}
resource "google_service_account_iam_member" "vpn_admins" {
  for_each           = var.cluster_admin_members
  service_account_id = google_service_account.vpn.name
  role               = "roles/iam.serviceAccountUser"
  member             = each.value
}
resource "google_compute_instance_iam_member" "vpn_admins" {
  for_each      = var.cluster_admin_members
  project       = var.project_id
  zone          = google_compute_instance.vpn.zone
  instance_name = google_compute_instance.vpn.name
  role          = "roles/compute.osAdminLogin"
  member        = each.value
}
resource "google_iap_tunnel_instance_iam_member" "vpn_admins" {
  for_each = var.cluster_admin_members
  project  = var.project_id
  zone     = google_compute_instance.vpn.zone
  instance = google_compute_instance.vpn.name
  role     = "roles/iap.tunnelResourceAccessor"
  member   = each.value
}
resource "google_compute_address" "vpn" {
  project = var.project_id
  name    = "${var.name}-vpn"
  region  = var.region
}
locals {
  routes = [var.vpc_cidr, var.pod_cidr, var.master_cidr]
}
resource "google_compute_instance" "vpn" {
  project        = var.project_id
  name           = "${var.name}-openvpn"
  zone           = data.google_compute_zones.available.names[0]
  machine_type   = "e2-small"
  can_ip_forward = true
  tags           = ["${var.name}-vpn"]
  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = 20
      type  = "pd-balanced"
    }
  }
  network_interface {
    subnetwork = var.public_subnet_ids[0]
    network_ip = var.vpn_private_ip
    access_config { nat_ip = google_compute_address.vpn.address }
  }
  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
  }
  service_account {
    email  = google_service_account.vpn.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
  shielded_instance_config {
    enable_secure_boot          = true
    enable_integrity_monitoring = true
  }
  metadata_startup_script = templatefile("${path.module}/../openvpn-bootstrap.sh.tftpl", {
    name        = var.name
    public_ip   = google_compute_address.vpn.address
    vpn_cidr    = var.vpn_client_cidr
    vpn_network = cidrhost(var.vpn_client_cidr, 0)
    vpn_gateway = cidrhost(var.vpn_client_cidr, 1)
    vpn_netmask = cidrnetmask(var.vpn_client_cidr)
    dns_server  = "169.254.169.254"
    routes      = [for cidr in local.routes : { cidr = cidr, network = cidrhost(cidr, 0), netmask = cidrnetmask(cidr) }]
  })
  depends_on = [google_project_service.required]
}

output "cluster_name" { value = google_container_cluster.this.name }
output "cluster_endpoint" { value = google_container_cluster.this.private_cluster_config[0].private_endpoint }
output "vpn_public_ip" { value = google_compute_address.vpn.address }
output "vpn_instance_id" { value = google_compute_instance.vpn.name }
output "vpn_zone" { value = google_compute_instance.vpn.zone }
output "security" {
  value = {
    private_api    = google_container_cluster.this.private_cluster_config[0].enable_private_endpoint
    private_nodes  = google_container_cluster.this.private_cluster_config[0].enable_private_nodes
    ha_workers     = length(google_container_node_pool.this.node_locations) == 3
    vpn_public_ssh = contains(google_compute_firewall.vpn_management.source_ranges, "0.0.0.0/0")
  }
}

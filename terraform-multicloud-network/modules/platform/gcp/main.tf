data "google_compute_zones" "available" {
  project = var.project_id
  region  = var.region
  status  = "UP"
}
resource "google_project_service" "required" {
  for_each           = toset(["compute.googleapis.com", "iam.googleapis.com", "iap.googleapis.com", "oslogin.googleapis.com", "run.googleapis.com", "artifactregistry.googleapis.com"])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_compute_firewall" "internal" {
  project       = var.project_id
  name          = "${var.name}-private-internal"
  network       = var.network_id
  direction     = "INGRESS"
  source_ranges = [var.vpc_cidr]
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
  routes = [var.vpc_cidr]
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
resource "google_service_account" "cloudrun" {
  project      = var.project_id
  account_id   = "${var.name}-cloudrun"
  display_name = "Cloud Run Service Account"
}

resource "google_cloud_run_v2_service" "app" {
  name     = "${var.name}-app"
  location = var.region

  template {
    service_account = google_service_account.cloudrun.email

    containers {
      image = "nginx:latest"
    }
  }
}

output "vpn_public_ip" { value = google_compute_address.vpn.address }
output "vpn_instance_id" { value = google_compute_instance.vpn.name }
output "vpn_zone" { value = google_compute_instance.vpn.zone }
output "security" {
  value = {
    vpn_public_ssh = contains(google_compute_firewall.vpn_management.source_ranges, "0.0.0.0/0")
  }
}

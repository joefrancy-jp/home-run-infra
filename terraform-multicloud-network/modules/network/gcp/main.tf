# ---------------- VPC ----------------
# In GCP the VPC is global and has no CIDR. Only subnets have ranges.
resource "google_compute_network" "this" {
  project                 = var.project_id
  name                    = "${var.name}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

# ---------------- Subnets ----------------
# GCP subnets are regional (they cover all zones in the region).
resource "google_compute_subnetwork" "public" {
  count         = length(var.public_subnet_cidrs)
  project       = var.project_id
  name          = "${var.name}-public-${count.index + 1}"
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = var.public_subnet_cidrs[count.index]
}

resource "google_compute_subnetwork" "private" {
  count                    = length(var.private_subnet_cidrs)
  project                  = var.project_id
  name                     = "${var.name}-private-${count.index + 1}"
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = var.private_subnet_cidrs[count.index]
  private_ip_google_access = true
  dynamic "secondary_ip_range" {
    for_each = count.index == 0 ? { pods = var.pod_cidr, services = var.service_cidr } : {}
    content {
      range_name    = secondary_ip_range.key
      ip_cidr_range = secondary_ip_range.value
    }
  }
}

resource "google_compute_subnetwork" "db" {
  count                    = length(var.db_subnet_cidrs)
  project                  = var.project_id
  name                     = "${var.name}-db-${count.index + 1}"
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = var.db_subnet_cidrs[count.index]
  private_ip_google_access = true
}

# ---------------- Cloud Router + Cloud NAT ----------------
resource "google_compute_router" "this" {
  project = var.project_id
  name    = "${var.name}-router"
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  project                = var.project_id
  name                   = "${var.name}-nat"
  router                 = google_compute_router.this.name
  region                 = var.region
  nat_ip_allocate_option = "AUTO_ONLY"

  # Only NAT the subnets we list below (private + db), not public.
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  dynamic "subnetwork" {
    for_each = concat(google_compute_subnetwork.private[*].id, google_compute_subnetwork.db[*].id)
    content {
      name                    = subnetwork.value
      source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
    }
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ---------------- Firewall ----------------
# Allow all traffic between machines inside the network.
resource "google_compute_firewall" "allow_internal" {
  project       = var.project_id
  name          = "${var.name}-allow-internal"
  network       = google_compute_network.this.id
  direction     = "INGRESS"
  source_ranges = [var.vpc_cidr]

  allow {
    protocol = "all"
  }
}

# Allow SSH only through Identity-Aware Proxy.
resource "google_compute_firewall" "allow_iap_ssh" {
  count         = var.allow_iap_ssh ? 1 : 0
  project       = var.project_id
  name          = "${var.name}-allow-iap-ssh"
  network       = google_compute_network.this.id
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

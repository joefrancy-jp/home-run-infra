variable "cluster_admin_identities" {
  description = "AWS role ARNs, GCP IAM members, or Azure Entra group object IDs"
  type        = set(string)
  validation {
    condition     = length(var.cluster_admin_identities) > 0
    error_message = "Configure at least one explicit cluster administrator."
  }
}
variable "vpn_ssh_public_key" {
  description = "Administrator public key; no private key is generated in Terraform"
  type        = string
  validation {
    condition     = can(regex("^(ssh-rsa|ssh-ed25519) ", var.vpn_ssh_public_key))
    error_message = "Supply a valid SSH public key."
  }
}
variable "vpn_source_cidrs" {
  description = "Allowed sources for certificate-authenticated UDP 1194 only"
  type        = list(string)
  default     = ["0.0.0.0/0"]
  validation {
    condition     = length(var.vpn_source_cidrs) > 0 && alltrue([for cidr in var.vpn_source_cidrs : can(cidrnetmask(cidr))])
    error_message = "Provide valid IPv4 VPN source CIDRs."
  }
}
variable "kubernetes_version" {
  description = "Optional supported version; null uses the cloud's default/release channel"
  type        = string
  default     = null
}
locals {
  pod_cidr     = "10.40.0.0/16"
  service_cidr = "10.41.0.0/20"
}
module "platform" {
  source                  = "../../../../modules/platform/aws"
  name                    = "${var.name}-${var.env}"
  env                     = var.env
  vpc_cidr                = var.vpc_cidr
  network_id              = module.network.network_id
  public_subnet_ids       = module.network.public_subnet_ids
  private_subnet_ids      = module.network.private_subnet_ids
  vpn_private_ip          = cidrhost(var.public_subnet_cidrs[0], 10)
  vpn_ssh_public_key      = var.vpn_ssh_public_key
  vpn_source_cidrs        = var.vpn_source_cidrs
  kubernetes_version      = var.kubernetes_version
  pod_cidr                = local.pod_cidr
  service_cidr            = local.service_cidr
  region                  = var.region
  cluster_admin_role_arns = var.cluster_admin_identities
  depends_on              = [module.network]
}

output "platform" {
  value = merge(module.platform, {
    cloud       = "aws"
    environment = var.env
    region      = var.region
    vpc_id      = module.network.network_id
    vpc_cidr    = var.vpc_cidr
  })
}

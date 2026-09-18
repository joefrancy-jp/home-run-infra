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
    condition     = can(regex("^ssh-rsa ", var.vpn_ssh_public_key))
    error_message = "Supply an RSA SSH public key for AKS compatibility."
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
  pod_cidr     = "10.50.0.0/16"
  service_cidr = "10.51.0.0/20"
}
module "platform" {
  source                  = "../../../../modules/platform/azure"
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
  location                = var.location
  resource_group_name     = module.network.resource_group_name
  vnet_name               = module.network.vnet_name
  db_subnet_ids           = module.network.db_subnet_ids
  cluster_admin_group_ids = tolist(var.cluster_admin_identities)
  tenant_id               = data.azurerm_client_config.current.tenant_id
  gateway_subnet_cidr     = cidrsubnet(var.vpc_cidr, 8, 30)
  depends_on              = [module.network]
}
data "azurerm_client_config" "current" {}

output "platform" {
  value = merge(module.platform, {
    cloud               = "azure"
    environment         = var.env
    region              = var.location
    resource_group_name = module.network.resource_group_name
    vpc_cidr            = var.vpc_cidr
  })
}

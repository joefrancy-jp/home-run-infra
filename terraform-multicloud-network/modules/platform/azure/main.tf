resource "azurerm_user_assigned_identity" "cluster" {
  name                = "${var.name}-aks"
  location            = var.location
  resource_group_name = var.resource_group_name
}
resource "azurerm_role_assignment" "network" {
  scope                = var.network_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.cluster.principal_id
}
resource "azurerm_subnet" "gateway" {
  name                 = "${var.name}-appgateway"
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.vnet_name
  address_prefixes     = [var.gateway_subnet_cidr]
}
resource "azurerm_network_security_group" "private" {
  name                = "${var.name}-private"
  location            = var.location
  resource_group_name = var.resource_group_name
  security_rule {
    name                       = "InternalOnly"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.vpc_cidr
    destination_address_prefix = var.vpc_cidr
  }
  security_rule {
    name                       = "AzureHealthChecks"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = var.vpc_cidr
  }
  security_rule {
    name                       = "DenyOtherInbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}
resource "azurerm_subnet_network_security_group_association" "private" {
  count                     = length(var.private_subnet_ids)
  subnet_id                 = var.private_subnet_ids[count.index]
  network_security_group_id = azurerm_network_security_group.private.id
}
resource "azurerm_subnet_network_security_group_association" "db" {
  count                     = length(var.db_subnet_ids)
  subnet_id                 = var.db_subnet_ids[count.index]
  network_security_group_id = azurerm_network_security_group.private.id
}
resource "azurerm_network_security_group" "gateway" {
  name                = "${var.name}-public-https"
  location            = var.location
  resource_group_name = var.resource_group_name
  security_rule {
    name                       = "PublicHTTPS"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "GatewayManagement"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "65200-65535"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "AzureHealthChecks"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "DenyOtherInbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}
resource "azurerm_subnet_network_security_group_association" "gateway" {
  subnet_id                 = azurerm_subnet.gateway.id
  network_security_group_id = azurerm_network_security_group.gateway.id
}
resource "azurerm_kubernetes_cluster" "this" {
  name                                = var.name
  location                            = var.location
  resource_group_name                 = var.resource_group_name
  dns_prefix                          = var.name
  kubernetes_version                  = var.kubernetes_version
  private_cluster_enabled             = true
  private_cluster_public_fqdn_enabled = false
  sku_tier                            = "Standard"
  role_based_access_control_enabled   = true
  local_account_disabled              = true
  oidc_issuer_enabled                 = true
  workload_identity_enabled           = true
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.cluster.id]
  }
  azure_active_directory_role_based_access_control {
    tenant_id              = var.tenant_id
    admin_group_object_ids = var.cluster_admin_group_ids
    azure_rbac_enabled     = false
  }
  default_node_pool {
    name                         = "system"
    vm_size                      = "Standard_D2s_v5"
    zones                        = ["1", "2", "3"]
    vnet_subnet_id               = var.private_subnet_ids[0]
    node_count                   = 3
    auto_scaling_enabled         = true
    min_count                    = 3
    max_count                    = 6
    max_pods                     = 30
    os_disk_type                 = "Managed"
    only_critical_addons_enabled = false
    upgrade_settings { max_surge = "1" }
  }
  linux_profile {
    admin_username = "azureuser"
    ssh_key { key_data = var.vpn_ssh_public_key }
  }
  network_profile {
    network_plugin    = "azure"
    network_policy    = "calico"
    service_cidr      = var.service_cidr
    dns_service_ip    = cidrhost(var.service_cidr, 10)
    outbound_type     = "userAssignedNATGateway"
    load_balancer_sku = "standard"
  }
  ingress_application_gateway {
    gateway_name = "${var.name}-appgateway"
    subnet_id    = azurerm_subnet.gateway.id
  }
  depends_on = [azurerm_role_assignment.network, azurerm_subnet_network_security_group_association.private, azurerm_subnet_network_security_group_association.gateway]
}
resource "azurerm_role_assignment" "agic_network" {
  scope                = var.network_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.this.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
}

resource "azurerm_public_ip" "vpn" {
  name                = "${var.name}-vpn"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}
resource "azurerm_network_interface" "vpn" {
  name                  = "${var.name}-vpn"
  location              = var.location
  resource_group_name   = var.resource_group_name
  ip_forwarding_enabled = true
  ip_configuration {
    name                          = "vpn"
    subnet_id                     = var.public_subnet_ids[0]
    private_ip_address_allocation = "Static"
    private_ip_address            = var.vpn_private_ip
    public_ip_address_id          = azurerm_public_ip.vpn.id
  }
}
resource "azurerm_network_security_group" "vpn" {
  name                = "${var.name}-vpn"
  location            = var.location
  resource_group_name = var.resource_group_name
  security_rule {
    name                       = "OpenVPN"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "1194"
    source_address_prefixes    = var.vpn_source_cidrs
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "PrivateSSH"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.vpc_cidr
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "DenyOtherInbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}
resource "azurerm_network_interface_security_group_association" "vpn" {
  network_interface_id      = azurerm_network_interface.vpn.id
  network_security_group_id = azurerm_network_security_group.vpn.id
}
resource "azurerm_linux_virtual_machine" "vpn" {
  name                            = "${var.name}-openvpn"
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = "Standard_B1ms"
  admin_username                  = "azureuser"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.vpn.id]
  admin_ssh_key {
    username   = "azureuser"
    public_key = var.vpn_ssh_public_key
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
  custom_data = base64encode(templatefile("${path.module}/../openvpn-bootstrap.sh.tftpl", {
    name        = var.name
    public_ip   = azurerm_public_ip.vpn.ip_address
    vpn_cidr    = var.vpn_client_cidr
    vpn_network = cidrhost(var.vpn_client_cidr, 0)
    vpn_gateway = cidrhost(var.vpn_client_cidr, 1)
    vpn_netmask = cidrnetmask(var.vpn_client_cidr)
    dns_server  = "168.63.129.16"
    routes      = [{ cidr = var.vpc_cidr, network = cidrhost(var.vpc_cidr, 0), netmask = cidrnetmask(var.vpc_cidr) }]
  }))
  depends_on = [azurerm_network_interface_security_group_association.vpn]
}

output "cluster_name" { value = azurerm_kubernetes_cluster.this.name }
output "cluster_endpoint" { value = azurerm_kubernetes_cluster.this.private_fqdn }
output "vpn_public_ip" { value = azurerm_public_ip.vpn.ip_address }
output "vpn_instance_id" { value = azurerm_linux_virtual_machine.vpn.name }
output "application_gateway_id" { value = azurerm_kubernetes_cluster.this.ingress_application_gateway[0].effective_gateway_id }
output "private_nsg_id" { value = azurerm_network_security_group.private.id }
output "security" {
  value = {
    private_api    = azurerm_kubernetes_cluster.this.private_cluster_enabled && !azurerm_kubernetes_cluster.this.private_cluster_public_fqdn_enabled
    ha_workers     = length(azurerm_kubernetes_cluster.this.default_node_pool[0].zones) == 3 && azurerm_kubernetes_cluster.this.sku_tier == "Standard"
    vpn_public_ssh = anytrue([for rule in azurerm_network_security_group.vpn.security_rule : rule.destination_port_range == "22" && rule.source_address_prefix == "*"])
  }
}

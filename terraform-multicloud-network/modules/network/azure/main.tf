# ---------------- Resource Group + VNet ----------------
# Azure's "VPC" is called a Virtual Network (VNet).
resource "azurerm_resource_group" "this" {
  name     = "${var.name}-rg"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.name}-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.vpc_cidr]
  tags                = var.tags
}

# ---------------- Subnets ----------------
resource "azurerm_subnet" "public" {
  count                = length(var.public_subnet_cidrs)
  name                 = "${var.name}-public-${count.index + 1}"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.public_subnet_cidrs[count.index]]
}

resource "azurerm_subnet" "private" {
  count                           = length(var.private_subnet_cidrs)
  name                            = "${var.name}-private-${count.index + 1}"
  resource_group_name             = azurerm_resource_group.this.name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.private_subnet_cidrs[count.index]]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "db" {
  count                           = length(var.db_subnet_cidrs)
  name                            = "${var.name}-db-${count.index + 1}"
  resource_group_name             = azurerm_resource_group.this.name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.db_subnet_cidrs[count.index]]
  default_outbound_access_enabled = false
}

# ---------------- NAT Gateway ----------------
resource "azurerm_public_ip" "nat" {
  name                = "${var.name}-nat-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "this" {
  name                    = "${var.name}-nat"
  location                = azurerm_resource_group.this.location
  resource_group_name     = azurerm_resource_group.this.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = var.tags
}

# Attach the public IP to the NAT gateway.
resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

# Attach the NAT gateway to private and db subnets.
resource "azurerm_subnet_nat_gateway_association" "private" {
  count          = length(azurerm_subnet.private)
  subnet_id      = azurerm_subnet.private[count.index].id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

resource "azurerm_subnet_nat_gateway_association" "db" {
  count          = length(azurerm_subnet.db)
  subnet_id      = azurerm_subnet.db[count.index].id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

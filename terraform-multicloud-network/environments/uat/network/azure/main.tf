terraform {
  required_version = ">= 1.10.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

module "network" {
  source = "../../../../modules/network/azure"

  name                 = "${var.name}-${var.env}"
  location             = var.location
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  db_subnet_cidrs      = var.db_subnet_cidrs

  tags = {
    Project   = var.name
    Env       = var.env
    ManagedBy = "terraform"
  }
}

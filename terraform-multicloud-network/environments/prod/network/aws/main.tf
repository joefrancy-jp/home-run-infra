terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
}

module "network" {
  source = "../../../../modules/network/aws"

  name                 = "${var.name}-${var.env}"
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  db_subnet_cidrs      = var.db_subnet_cidrs
  single_nat_gateway   = var.single_nat_gateway

  tags = {
    Project   = var.name
    Env       = var.env
    ManagedBy = "terraform"
  }
}

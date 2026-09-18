variable "name" {
  description = "Prefix used in every resource name"
  type        = string
}

variable "vpc_cidr" {
  description = "Main network range, e.g. 172.16.0.0/16"
  type        = string
}

variable "public_subnet_cidrs" {
  description = "Exactly 3 CIDRs for public subnets"
  type        = list(string)
  validation {
    condition     = length(var.public_subnet_cidrs) == 3 && alltrue([for c in var.public_subnet_cidrs : try(cidrsubnet(c, 0, 0) == c, false)])
    error_message = "Provide exactly 3 valid CIDRs. Each must start on a real network boundary (172.16.1.0/24 is valid, 172.16.1.0/20 is not)."
  }
}

variable "private_subnet_cidrs" {
  description = "Exactly 3 CIDRs for private subnets"
  type        = list(string)
  validation {
    condition     = length(var.private_subnet_cidrs) == 3 && alltrue([for c in var.private_subnet_cidrs : try(cidrsubnet(c, 0, 0) == c, false)])
    error_message = "Provide exactly 3 valid CIDRs. Each must start on a real network boundary."
  }
}

variable "db_subnet_cidrs" {
  description = "Exactly 3 CIDRs for database subnets"
  type        = list(string)
  validation {
    condition     = length(var.db_subnet_cidrs) == 3 && alltrue([for c in var.db_subnet_cidrs : try(cidrsubnet(c, 0, 0) == c, false)])
    error_message = "Provide exactly 3 valid CIDRs. Each must start on a real network boundary."
  }
}

variable "region" {
  description = "AWS region (needs at least 3 availability zones)"
  type        = string
}

variable "single_nat_gateway" {
  description = "true = 1 NAT for all AZs (cheaper). false = 1 NAT per AZ (highly available)"
  type        = bool
  default     = true
}

variable "env" {
  description = "Environment name, e.g. dev, stage, prod (passed in by deploy.sh)"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]+$", var.env))
    error_message = "env must be lowercase letters and numbers only, e.g. dev, stage, prod."
  }
}

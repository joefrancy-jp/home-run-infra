variable "name" {
  type = string
}

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_cidr" {
  description = "Used for the internal firewall rule (GCP VPCs have no CIDR of their own)"
  type        = string
}

variable "public_subnet_cidrs" {
  type = list(string)
}

variable "private_subnet_cidrs" {
  type = list(string)
}

variable "db_subnet_cidrs" {
  type = list(string)
}

variable "allow_iap_ssh" {
  description = "Allow SSH from Google IAP range (35.235.240.0/20)"
  type        = bool
  default     = false
}

variable "pod_cidr" { type = string }
variable "service_cidr" { type = string }

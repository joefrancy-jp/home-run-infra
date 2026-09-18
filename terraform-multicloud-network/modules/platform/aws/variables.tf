variable "name" { type = string }
variable "env" { type = string }
variable "vpc_cidr" { type = string }
variable "network_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "private_subnet_ids" { type = list(string) }
variable "vpn_private_ip" { type = string }
variable "vpn_ssh_public_key" { type = string }
variable "vpn_client_cidr" {
  type    = string
  default = "10.250.0.0/24"
}
variable "vpn_source_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}
variable "kubernetes_version" {
  type    = string
  default = null
}
variable "service_cidr" { type = string }
variable "pod_cidr" { type = string }
variable "region" { type = string }
variable "cluster_admin_role_arns" { type = set(string) }

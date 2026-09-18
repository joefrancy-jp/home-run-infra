# ---------------- General ----------------
# Prefix for every resource name. Final names look like: platform-dev-vpc
name = "platform"

# This root owns the production infrastructure.
env = "prod"

# ---------------- Network ----------------
vpc_cidr = "172.16.0.0/16"

# 3 public subnets: reach the internet directly
public_subnet_cidrs = [
  "172.16.1.0/24",
  "172.16.2.0/24",
  "172.16.3.0/24",
]

# 3 private subnets: outbound internet through NAT only
private_subnet_cidrs = [
  "172.16.11.0/24",
  "172.16.12.0/24",
  "172.16.13.0/24",
]

# 3 database subnets: outbound internet through NAT only
db_subnet_cidrs = [
  "172.16.21.0/24",
  "172.16.22.0/24",
  "172.16.23.0/24",
]

# ---------------- Azure ----------------
subscription_id = "00000000-0000-0000-0000-000000000000"
location        = "centralindia"

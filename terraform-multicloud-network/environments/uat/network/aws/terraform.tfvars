# ---------------- General ----------------
# Prefix for every resource name. Final names look like: platform-dev-vpc
name = "platform"

# This root owns the on-demand UAT load-test infrastructure.
env = "uat"

# ---------------- Network ----------------
vpc_cidr = "172.18.0.0/16"

# 3 public subnets: reach the internet directly
public_subnet_cidrs = [
  "172.18.1.0/24",
  "172.18.2.0/24",
  "172.18.3.0/24",
]

# 3 private subnets: outbound internet through NAT only
private_subnet_cidrs = [
  "172.18.11.0/24",
  "172.18.12.0/24",
  "172.18.13.0/24",
]

# 3 database subnets: outbound internet through NAT only
db_subnet_cidrs = [
  "172.18.21.0/24",
  "172.18.22.0/24",
  "172.18.23.0/24",
]

# ---------------- AWS ----------------
# Region must have at least 3 availability zones
region = "ap-south-1"

# true  = 1 NAT Gateway shared by all zones (cheaper, good for dev)
# false = 1 NAT Gateway per zone (survives a zone outage, better for prod)
single_nat_gateway = true

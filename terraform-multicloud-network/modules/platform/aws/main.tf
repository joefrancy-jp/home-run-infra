data "aws_partition" "current" {}
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  partition = data.aws_partition.current.partition
  routes    = [var.vpc_cidr]
  vpn_bootstrap = templatefile("${path.module}/../openvpn-bootstrap.sh.tftpl", {
    name        = var.name
    public_ip   = aws_eip.vpn.public_ip
    vpn_cidr    = var.vpn_client_cidr
    vpn_network = cidrhost(var.vpn_client_cidr, 0)
    vpn_gateway = cidrhost(var.vpn_client_cidr, 1)
    vpn_netmask = cidrnetmask(var.vpn_client_cidr)
    dns_server  = cidrhost(var.vpc_cidr, 2)
    routes      = [for cidr in local.routes : { cidr = cidr, network = cidrhost(cidr, 0), netmask = cidrnetmask(cidr) }]
  })
}

resource "aws_security_group" "vpn" {
  name_prefix = "${var.name}-vpn-"
  description = "OpenVPN certificates required; no public SSH"
  vpc_id      = var.network_id
  ingress {
    protocol    = "udp"
    from_port   = 1194
    to_port     = 1194
    cidr_blocks = var.vpn_source_cidrs
  }
  ingress {
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = [var.vpc_cidr]
  }
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "nodes" {
  name_prefix = "${var.name}-nodes-"
  description = "Private workers; internal traffic and explicit ALB access only"
  vpc_id      = var.network_id
  ingress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = [var.vpc_cidr]
  }
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "control_plane" {
  name_prefix = "${var.name}-control-"
  description = "Private EKS API from VPC and SNATed VPN clients"
  vpc_id      = var.network_id
  ingress {
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = [var.vpc_cidr]
  }
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = [var.vpc_cidr]
  }
}
resource "aws_security_group" "database" {
  name_prefix = "${var.name}-database-"
  description = "Attach to databases: VPC clients only"
  vpc_id      = var.network_id
  ingress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = [var.vpc_cidr]
  }
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = [var.vpc_cidr]
  }
}
resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  description = "Public HTTPS edge; only private gateway targets"
  vpc_id      = var.network_id
  ingress {
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    protocol        = "tcp"
    from_port       = 8000
    to_port         = 8000
    security_groups = [aws_security_group.nodes.id]
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name}-eks-control"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "eks.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}
resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}
resource "aws_eks_cluster" "this" {
  name                      = var.name
  role_arn                  = aws_iam_role.cluster.arn
  version                   = var.kubernetes_version
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }
  vpc_config {
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [aws_security_group.control_plane.id]
    endpoint_private_access = true
    endpoint_public_access  = false
  }
  kubernetes_network_config {
    service_ipv4_cidr = var.service_cidr
  }
  depends_on = [aws_iam_role_policy_attachment.cluster]
}
resource "aws_eks_access_entry" "admins" {
  for_each      = var.cluster_admin_role_arns
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}
resource "aws_eks_access_policy_association" "admins" {
  for_each      = var.cluster_admin_role_arns
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.admins[each.key].principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
}
resource "aws_iam_role" "nodes" {
  name               = "${var.name}-eks-nodes"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}
resource "aws_iam_role_policy_attachment" "nodes" {
  for_each   = toset(["AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryPullOnly", "AmazonEKS_CNI_Policy", "AmazonSSMManagedInstanceCore"])
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}
resource "aws_key_pair" "vpn" {
  key_name_prefix = "${var.name}-admin-"
  public_key      = var.vpn_ssh_public_key
}
resource "aws_launch_template" "nodes" {
  name_prefix            = "${var.name}-nodes-"
  vpc_security_group_ids = [aws_security_group.nodes.id]
  key_name               = aws_key_pair.vpn.key_name
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      encrypted   = true
      volume_size = 50
      volume_type = "gp3"
    }
  }
}
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "private"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = ["m6i.large"]
  ami_type        = "AL2023_x86_64_STANDARD"
  scaling_config {
    desired_size = 3
    min_size     = 3
    max_size     = 9
  }
  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }
  update_config { max_unavailable = 1 }
  depends_on = [aws_iam_role_policy_attachment.nodes]
}
resource "aws_eks_addon" "pod_identity" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "eks-pod-identity-agent"
  depends_on   = [aws_eks_node_group.this]
}
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  configuration_values        = jsonencode({ enableNetworkPolicy = "true" })
  resolve_conflicts_on_create = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.this]
}
resource "aws_iam_role" "alb" {
  name               = "${var.name}-alb-controller"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "pods.eks.amazonaws.com" }, Action = ["sts:AssumeRole", "sts:TagSession"] }] })
}
resource "aws_iam_policy" "alb" {
  name   = "${var.name}-alb-controller"
  policy = file("${path.module}/alb-iam-policy.json")
}
resource "aws_iam_role_policy_attachment" "alb" {
  role       = aws_iam_role.alb.name
  policy_arn = aws_iam_policy.alb.arn
}
resource "aws_eks_pod_identity_association" "alb" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.alb.arn
}

resource "aws_iam_role" "vpn" {
  name               = "${var.name}-vpn-ssm"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}
resource "aws_iam_role_policy_attachment" "vpn" {
  role       = aws_iam_role.vpn.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_instance_profile" "vpn" {
  name = "${var.name}-vpn"
  role = aws_iam_role.vpn.name
}
resource "aws_eip" "vpn" { domain = "vpc" }
resource "aws_instance" "vpn" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = var.public_subnet_ids[0]
  private_ip                  = var.vpn_private_ip
  associate_public_ip_address = true
  source_dest_check           = false
  vpc_security_group_ids      = [aws_security_group.vpn.id]
  key_name                    = aws_key_pair.vpn.key_name
  iam_instance_profile        = aws_iam_instance_profile.vpn.name
  user_data                   = local.vpn_bootstrap
  user_data_replace_on_change = true
  metadata_options { http_tokens = "required" }
  root_block_device {
    encrypted   = true
    volume_type = "gp3"
  }
  tags = { Name = "${var.name}-openvpn" }
}
resource "aws_eip_association" "vpn" {
  allocation_id = aws_eip.vpn.id
  instance_id   = aws_instance.vpn.id
}

output "cluster_name" { value = aws_eks_cluster.this.name }
output "cluster_endpoint" { value = aws_eks_cluster.this.endpoint }
output "vpn_public_ip" { value = aws_eip.vpn.public_ip }
output "vpn_instance_id" { value = aws_instance.vpn.id }
output "alb_security_group_id" { value = aws_security_group.alb.id }
output "node_security_group_id" { value = aws_security_group.nodes.id }
output "database_security_group_id" { value = aws_security_group.database.id }
output "security" {
  value = {
    private_api    = aws_eks_cluster.this.vpc_config[0].endpoint_private_access && !aws_eks_cluster.this.vpc_config[0].endpoint_public_access
    ha_workers     = length(aws_eks_node_group.this.subnet_ids) == 3 && aws_eks_node_group.this.scaling_config[0].min_size >= 3
    vpn_public_ssh = anytrue([for rule in aws_security_group.vpn.ingress : rule.from_port == 22 && contains(rule.cidr_blocks, "0.0.0.0/0")])
  }
}

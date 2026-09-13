# ---------------------------------------------------------------------------
# PUBLIC SUBNETS ONLY. NO NAT GATEWAY. This is deliberate.
#
# A NAT Gateway is $0.045/hr plus $0.045/GB. Left running it is ~$32/mo, which
# for this cluster would cost MORE than the nodes and roughly half again the
# control plane. Almost every EKS reference architecture and module default
# creates one; for an 8-hour training sandbox it is pure waste.
#
# The trade: nodes have public IPs and are protected by security groups rather
# than by being unroutable. That is not a production pattern and should not be
# copied into one. It is the right call for a cluster that lives 8 hours.
# ---------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # required for EKS

  tags = { Name = var.cluster_name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.cluster_name }
}

resource "aws_subnet" "public" {
  count = length(var.azs)

  vpc_id                  = aws_vpc.this.id
  availability_zone       = var.azs[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.cluster_name}-public-${var.azs[count.index]}"
    # Subnet discovery tag for the AWS Load Balancer Controller. Not used in
    # phase 0 (no ingress) but placed now: adding it later means recreating
    # or retagging subnets while an ALB is mid-provision.
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.cluster_name}-public" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

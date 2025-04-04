module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.13.0"

  name = "aviatrix"
  cidr = var.cidr

  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  enable_nat_gateway = true
  single_nat_gateway = true
  enable_vpn_gateway = false
}

resource "aws_security_group" "this" {
  name        = "aviatrix"
  description = "security group for aviatrix gatus instances"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_security_group_rule" "this_ingress" {
  type              = "ingress"
  description       = "Allow inbound http access"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["10.0.0.0/8", "192.168.0.0/16", "172.16.0.0/12"]
  security_group_id = aws_security_group.this.id
}

resource "aws_security_group_rule" "this_dashboard" {
  count             = var.dashboard ? 1 : 0
  type              = "ingress"
  description       = "Allow inbound internet http access"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = [var.dashboard_access_ip]
  security_group_id = aws_security_group.this.id
}

resource "aws_security_group_rule" "this_egress" {
  type              = "egress"
  description       = "Allow outbound access"
  from_port         = 0
  to_port           = 0
  protocol          = "all"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.this.id
}

data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

module "gatus_instances" {
  for_each = toset(formatlist("%d", range(var.number_of_subnets)))
  source   = "terraform-aws-modules/ec2-instance/aws"

  name = "aviatrix-gatus-az${each.value + 1}"

  instance_type          = "t3.micro"
  vpc_security_group_ids = [aws_security_group.this.id]
  subnet_id              = element(module.vpc.private_subnets, each.key)
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value

  user_data = templatefile("${path.module}/../templates/gatus.tpl",
    {
      name     = "gatus-az${each.value + 1}"
      user     = var.local_user
      password = var.local_user_password
      https    = var.gatus_endpoints.https
      http     = var.gatus_endpoints.http
      tcp      = var.gatus_endpoints.tcp
      icmp     = var.gatus_endpoints.icmp
      interval = var.gatus_interval
      version  = var.gatus_version
  })
  depends_on = [module.vpc]
}

module "dashboard" {
  count  = var.dashboard ? 1 : 0
  source = "terraform-aws-modules/ec2-instance/aws"

  name = "aviatrix-gatus-dashboard"

  instance_type               = "t3.micro"
  vpc_security_group_ids      = [aws_security_group.this.id]
  subnet_id                   = module.vpc.public_subnets[0]
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/../templates/dashboard.tpl",
    {
      cloud     = "aws"
      instances = [for instance in module.gatus_instances : instance.private_ip]
      version   = var.gatus_version
  })
  depends_on = [module.gatus_instances]
}

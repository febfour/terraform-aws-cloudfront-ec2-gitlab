terraform {
  required_version = ">= 0.13.1"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.83"
    }
  }
}

variable "enable_nat" {
  description = "Enable or disable NAT Gateway during setup"
  type        = bool
  default     = true
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

##############################
# VPC
##############################
data "aws_vpc" "default" {
  default = true
}

##############################
# Default Subnet
##############################
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

##############################
# Internet Gateway
##############################
data "aws_internet_gateway" "default" {
  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

##############################
# Private Subnet
##############################
resource "aws_subnet" "private" {
  vpc_id                  = data.aws_vpc.default.id
  cidr_block              = "172.31.200.0/24"
  availability_zone       = "us-east-1d"
  map_public_ip_on_launch = false
  tags = {
    Name = "PrivateSubnet"
  }
}

##############################
# NAT Gateway
##############################
resource "aws_eip" "nat" {
  count  = var.enable_nat ? 1 : 0
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  count         = var.enable_nat ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  # Nat Gateway in VPC Default Subnet
  subnet_id = element(data.aws_subnets.default.ids, 0)
  depends_on = [data.aws_internet_gateway.default]
}

resource "aws_route_table" "private_rt" {
  count  = var.enable_nat ? 1 : 0
  vpc_id = data.aws_vpc.default.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat[0].id
  }
}

resource "aws_route_table_association" "private_rt_assoc" {
  count          = var.enable_nat ? 1 : 0
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private_rt[0].id
}

##############################
# GitLab Security Group
##############################
resource "aws_security_group" "gitlab_sg" {
  name        = "gitlab-sg"
  description = "Allow HTTP, HTTPS and SSH for GitLab"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Allow HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

##############################
# Amazon Linux 2 AMI
##############################
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

##############################
# Session Manager IAM ROle
##############################
resource "aws_iam_role" "ssm" {
  name = "EC2SessionManagerRole"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_attachment" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "EC2SessionManagerInstanceProfile"
  role = aws_iam_role.ssm.name
}

##############################
# GitLab Docker EC2 in Private Subnet
##############################
resource "aws_instance" "gitlab" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.gitlab_sg.id]
  associate_public_ip_address = false
  iam_instance_profile   = aws_iam_instance_profile.ssm.name

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              amazon-linux-extras install docker -y
              service docker start
              usermod -a -G docker ec2-user
              # GitLab Container
              docker run --detach \
                --publish 80:80 \
                --name gitlab \
                --restart always \
                -v /srv/gitlab/config:/etc/gitlab \
                -v /srv/gitlab/logs:/var/log/gitlab \
                -v /srv/gitlab/data:/var/opt/gitlab \
                gitlab/gitlab-ce:latest
              EOF

  tags = {
    Name = "GitLab-Instance"
  }
}

##############################
# random name
##############################
resource "random_pet" "this" {
  length = 2
}

##############################
# CloudFront
##############################
module "cloudfront" {
  source  = "terraform-aws-modules/cloudfront/aws"

  create_vpc_origin = true

  vpc_origin = {
    ec2_vpc_origin = {
      name                   = random_pet.this.id
      arn                    = "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.gitlab.id}"
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols = {
        items    = ["TLSv1.2"]
        quantity = 1
      }
    }
  }

  origin = {
    ec2_vpc_origin = {
      domain_name = aws_instance.gitlab.private_dns
      vpc_origin_config = {
        vpc_origin = "ec2_vpc_origin"
      }
    }
  }

  default_cache_behavior = {
    target_origin_id       = "ec2_vpc_origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
  }

  enabled = true

  viewer_certificate = {
    cloudfront_default_certificate = true
  }

  web_acl_id = aws_wafv2_web_acl.cloudfront_acl.arn
}

##############################
# AWS WAFv2 for CloudFront
##############################
resource "aws_wafv2_ip_set" "allowed_ips" {
  name               = "AllowedIPs"
  description        = "Allowed IP addresses for CloudFront access"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"
  addresses          = [
    "0.0.0.0/0"
  ]
}

resource "aws_wafv2_web_acl" "cloudfront_acl" {
  name        = "CloudFrontIPRestrictACL"
  description = "Web ACL to restrict access to allowed IP addresses"
  scope       = "CLOUDFRONT"

  default_action {
    block {}
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "cloudfront_ip_restrict_acl"
    sampled_requests_enabled   = true
  }

  rule {
    name     = "AllowFromSpecificIPs"
    priority = 1
    action {
      allow {}
    }
    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.allowed_ips.arn
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AllowFromSpecificIPs"
      sampled_requests_enabled   = true
    }
  }
}

##############################
# VPC endpoint security group
##############################
resource "aws_security_group" "ssm_endpoint_sg" {
  name        = "ssm-endpoint-sg"
  description = "Security group for SSM and SSMMessages VPC endpoints"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Allow HTTPS from GitLab instance SG"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.gitlab_sg.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Specify subnets in different AZs for VPC endpoints to avoid duplicates in the same AZ
data "aws_subnet" "endpoint_az1" {
  filter {
    name   = "availability-zone"
    values = ["us-east-1a"]
  }
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_subnet" "endpoint_az2" {
  filter {
    name   = "availability-zone"
    values = ["us-east-1b"]
  }
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = data.aws_vpc.default.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [data.aws_subnet.endpoint_az1.id]
  security_group_ids  = [aws_security_group.ssm_endpoint_sg.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = data.aws_vpc.default.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [data.aws_subnet.endpoint_az2.id]
  security_group_ids  = [aws_security_group.ssm_endpoint_sg.id]
  private_dns_enabled = true
}

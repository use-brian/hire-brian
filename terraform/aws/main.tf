terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" { region = var.region }

data "aws_ami" "debian" {
  most_recent = true
  owners      = ["136693071363"]
  filter {
    name   = "name"
    values = ["debian-12-amd64-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_vpc" "brian" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "${var.name}-vpc" }
}

resource "aws_internet_gateway" "brian" {
  vpc_id = aws_vpc.brian.id
}

resource "aws_subnet" "brian" {
  vpc_id                  = aws_vpc.brian.id
  cidr_block              = "10.42.1.0/24"
  map_public_ip_on_launch = true
  tags = { Name = "${var.name}-subnet" }
}

resource "aws_route_table" "brian" {
  vpc_id = aws_vpc.brian.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.brian.id
  }
}

resource "aws_route_table_association" "brian" {
  subnet_id      = aws_subnet.brian.id
  route_table_id = aws_route_table.brian.id
}

resource "aws_security_group" "brian" {
  name   = "${var.name}-ssh"
  vpc_id = aws_vpc.brian.id
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "brian" {
  ami                         = data.aws_ami.debian.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.brian.id
  vpc_security_group_ids      = [aws_security_group.brian.id]
  associate_public_ip_address = true
  key_name                    = var.key_name
  root_block_device {
    volume_size = var.disk_size_gb
    volume_type = "gp3"
    encrypted   = true
  }
  metadata_options {
    http_tokens = "required"
  }
  tags = { Name = var.name }
}

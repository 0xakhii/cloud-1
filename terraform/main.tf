# =============================================================================
# Cloud-1 — AWS Infrastructure with Terraform
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ---------------------------------------------------------------------------
# Auto-lookup latest Ubuntu 22.04 LTS AMI
# ---------------------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------------------------------------------------------
# Security Group — only 22, 80, 443
# ---------------------------------------------------------------------------
resource "aws_security_group" "cloud1" {
  name        = "cloud-1-sg"
  description = "Cloud-1: SSH, HTTP, HTTPS only"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "cloud-1"
  }
}

# ---------------------------------------------------------------------------
# EC2 Instance
# ---------------------------------------------------------------------------
resource "aws_instance" "cloud1" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.cloud1.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name = "cloud-1"
  }
}

# ---------------------------------------------------------------------------
# Elastic IP — keeps the same IP across stop/start cycles
# ---------------------------------------------------------------------------
resource "aws_eip" "cloud1" {
  instance = aws_instance.cloud1.id

  tags = {
    Name = "cloud-1"
  }
}

# ---------------------------------------------------------------------------
# Auto-generate Ansible inventory (uses Elastic IP)
# ---------------------------------------------------------------------------
resource "local_file" "ansible_inventory" {
  content         = "[web]\n${aws_eip.cloud1.public_ip} ansible_user=ubuntu ansible_ssh_private_key_file=${var.ssh_private_key_path}\n"
  filename        = "${path.module}/../inventories/cloud.ini"
  file_permission = "0644"
}

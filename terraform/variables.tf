# =============================================================================
# Cloud-1 — Terraform Variables
# =============================================================================

variable "aws_region" {
  description = "AWS region to deploy in"
  type        = string
  default     = "eu-west-3"
}

variable "instance_type" {
  description = "EC2 instance type (t3.micro is free-tier eligible)"
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "Name of your existing AWS key pair"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Local path to the SSH private key (.pem file)"
  type        = string
  default     = "~/.ssh/id_rsa"
}

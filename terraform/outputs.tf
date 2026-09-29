# =============================================================================
# Cloud-1 — Terraform Outputs
# =============================================================================

output "instance_id" {
  description = "EC2 instance ID (used by deploy.sh stop/start)"
  value       = aws_instance.cloud1.id
}

output "server_ip" {
  description = "Elastic IP of the EC2 instance"
  value       = aws_eip.cloud1.public_ip
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

output "ssh_command" {
  description = "SSH command to connect to the server"
  value       = "ssh -i ${var.ssh_private_key_path} ubuntu@${aws_eip.cloud1.public_ip}"
}

output "wordpress_url" {
  description = "WordPress URL"
  value       = "https://${aws_eip.cloud1.public_ip}"
}

output "phpmyadmin_url" {
  description = "phpMyAdmin URL"
  value       = "https://${aws_eip.cloud1.public_ip}/phpmyadmin/"
}

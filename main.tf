# =============================================================================
# main.tf — Complete EC2 Infrastructure
# Managed By : Terraform
# Description: EC2 instance with SG, EBS volumes, and optional IAM profile
# =============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.3.0"
}

# -----------------------------------------------------------------------------
# PROVIDER
# -----------------------------------------------------------------------------
provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

# -----------------------------------------------------------------------------
# VARIABLES
# -----------------------------------------------------------------------------
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-2"
}

variable "aws_access_key" {
  description = "AWS Access Key ID"
  type        = string
  sensitive   = true
  default = "AKIASY7GLOWZ6BEYMK6I"
}

variable "aws_secret_key" {
  description = "AWS Secret Access Key"
  type        = string
  sensitive   = true
  default = "mnE4mdLsZQLMt6snUA4B+qU5RsbCfxji2JCNNhKX"
}

variable "environment" {
  description = "Environment name (dev / uat / prod)"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Project or application name"
  type        = string
  default     = "myapp"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "ami_id" {
  description = "AMI ID — leave blank to auto-resolve latest Amazon Linux 2023"
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for the EC2 instance"
  type        = string
}

variable "associate_public_ip" {
  description = "Associate a public IP address"
  type        = bool
  default     = false
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 50
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed SSH access"
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "iam_instance_profile" {
  description = "IAM instance profile name (optional)"
  type        = string
  default     = null
}

variable "additional_ebs_volumes" {
  description = "Additional EBS volumes to attach"
  type = list(object({
    device_name = string
    size        = number
    volume_type = string
    encrypted   = bool
  }))
  default = []
}

# -----------------------------------------------------------------------------
# DATA SOURCES
# -----------------------------------------------------------------------------

# Latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# -----------------------------------------------------------------------------
# LOCALS
# -----------------------------------------------------------------------------
locals {
  resolved_ami = var.ami_id != "" ? var.ami_id : data.aws_ami.amazon_linux_2023.id

  common_tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "Terraform"
  }
}

# -----------------------------------------------------------------------------
# SECURITY GROUP
# -----------------------------------------------------------------------------
resource "aws_security_group" "ec2_sg" {
  name        = "${var.project_name}-${var.environment}-ec2-sg"
  description = "Security group for ${var.project_name} EC2 instance"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH from allowed CIDRs"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-ec2-sg"
  })
}

# -----------------------------------------------------------------------------
# EC2 INSTANCE
# -----------------------------------------------------------------------------
resource "aws_instance" "main" {
  ami                         = local.resolved_ami
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  associate_public_ip_address = var.associate_public_ip
  iam_instance_profile        = var.iam_instance_profile

  vpc_security_group_ids = [aws_security_group.ec2_sg.id]

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true

    tags = merge(local.common_tags, {
      Name = "${var.project_name}-${var.environment}-root-vol"
    })
  }

  # IMDSv2 enforced — security best practice
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  # Bootstrap: hostname + SSM Agent
  user_data = base64encode(<<-EOF
    #!/bin/bash
    hostnamectl set-hostname ${var.project_name}-${var.environment}
    yum update -y
    yum install -y amazon-ssm-agent
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent
  EOF
  )

  monitoring = true  # Enable detailed CloudWatch monitoring

  lifecycle {
    ignore_changes = [ami]  # Prevent forced replacement on AMI updates
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-ec2"
  })
}

# -----------------------------------------------------------------------------
# ADDITIONAL EBS VOLUMES (optional)
# -----------------------------------------------------------------------------
resource "aws_ebs_volume" "additional" {
  count             = length(var.additional_ebs_volumes)
  availability_zone = aws_instance.main.availability_zone
  size              = var.additional_ebs_volumes[count.index].size
  type              = var.additional_ebs_volumes[count.index].volume_type
  encrypted         = var.additional_ebs_volumes[count.index].encrypted

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-data-vol-${count.index + 1}"
  })
}

resource "aws_volume_attachment" "additional" {
  count       = length(var.additional_ebs_volumes)
  device_name = var.additional_ebs_volumes[count.index].device_name
  volume_id   = aws_ebs_volume.additional[count.index].id
  instance_id = aws_instance.main.id
}

# -----------------------------------------------------------------------------
# OUTPUTS
# -----------------------------------------------------------------------------
output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.main.id
}

output "private_ip" {
  description = "Private IP address"
  value       = aws_instance.main.private_ip
}

output "public_ip" {
  description = "Public IP address (if assigned)"
  value       = aws_instance.main.public_ip
}

output "ami_used" {
  description = "AMI ID resolved and used"
  value       = local.resolved_ami
}

output "security_group_id" {
  description = "Security group ID"
  value       = aws_security_group.ec2_sg.id
}

output "availability_zone" {
  description = "Availability zone of the instance"
  value       = aws_instance.main.availability_zone
}

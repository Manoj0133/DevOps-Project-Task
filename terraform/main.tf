terraform {
  required_version = ">= 1.5.0"

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

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_subnet" "selected" {
  id = data.aws_subnets.default.ids[0]
}

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

locals {
  caddy_email          = var.caddy_email != "" ? var.caddy_email : "admin@${var.domain_name}"
  public_base_url      = var.public_base_url != "" ? var.public_base_url : "https://${var.domain_name}"
  repository_clone_url = var.repository_clone_url != "" ? var.repository_clone_url : "https://github.com/${var.github_repository}.git"
  ghcr_image           = var.ghcr_image != "" ? var.ghcr_image : "ghcr.io/${var.github_repository}"
}

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com",
  ]

  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
  ]
}

resource "aws_iam_role" "ec2_ssm" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm_core" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_ssm.name
}

resource "aws_iam_role" "github_actions" {
  name = "${var.project_name}-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:ref:refs/heads/${var.github_branch}"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "github_actions" {
  name = "${var.project_name}-github-actions-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeTags"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
          "ssm:ListCommandInvocations"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_security_group" "statuspulse" {
  name        = "${var.project_name}-sg"
  description = "StatusPulse web traffic"
  vpc_id      = data.aws_vpc.default.id

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
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-sg"
    Project = var.project_name
  }
}

resource "aws_instance" "statuspulse" {
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnet.selected.id
  vpc_security_group_ids      = [aws_security_group.statuspulse.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  user_data_replace_on_change = true

  user_data = <<-EOF
#!/bin/bash
set -euo pipefail

dnf update -y
dnf install -y docker docker-compose-plugin git curl openssl awscli python3 cronie
systemctl enable --now docker
systemctl enable --now amazon-ssm-agent || true
systemctl enable --now crond
usermod -aG docker ec2-user || true

mkdir -p /opt/statuspulse /opt/statuspulse/backups /opt/statuspulse/logs /var/log/statuspulse

if [ ! -d /opt/statuspulse/.git ]; then
  git clone --branch ${var.github_branch} --single-branch ${local.repository_clone_url} /opt/statuspulse
else
  cd /opt/statuspulse
  git remote set-url origin ${local.repository_clone_url}
  git fetch --all --prune
  git checkout ${var.github_branch}
fi

git config --system --add safe.directory /opt/statuspulse || true

chmod -R u+rwX,go+rX /opt/statuspulse || true
chown -R ec2-user:ec2-user /opt/statuspulse
touch /opt/statuspulse/logs/statuspulse-monitor.log
chown ec2-user:ec2-user /opt/statuspulse/logs/statuspulse-monitor.log

cat >/opt/statuspulse/.env <<ENV
APP_PORT=8000
APP_IMAGE=${local.ghcr_image}:latest
DB_HOST=db
DB_PORT=5432
DB_NAME=statuspulse
DB_USER=statuspulse
DB_PASSWORD=$(openssl rand -hex 24)
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=$(openssl rand -hex 24)
RATE_LIMIT_REQUESTS=60
RATE_LIMIT_WINDOW_SECONDS=60
APP_BLUE_IMAGE=${local.ghcr_image}:latest
APP_GREEN_IMAGE=${local.ghcr_image}:latest
ACTIVE_SLOT=blue
APP_UPSTREAM_HOST=app_blue
DOMAIN=${var.domain_name}
PUBLIC_BASE_URL=${local.public_base_url}
PUBLIC_HEALTH_URL=${local.public_base_url}/health
CADDY_EMAIL=${local.caddy_email}
UPTIME_KUMA_PORT=3001
ALERT_WEBHOOK_URL=
EXPECTED_CONTAINERS=statuspulse-caddy statuspulse-db statuspulse-redis
DB_CONTAINER=statuspulse-db
REDIS_CONTAINER=statuspulse-redis
TLS_HOST=${var.domain_name}
TLS_PORT=443
TLS_WARN_DAYS=14
DISK_WARN_PCT=80
MEMORY_WARN_PCT=90
MONITOR_PATH=/
HTTP_TIMEOUT_SECONDS=10
WEBHOOK_TIMEOUT_SECONDS=10
TCP_TIMEOUT_SECONDS=3
LOG_FILE=/opt/statuspulse/logs/statuspulse-monitor.log
BACKUP_DIR=/opt/statuspulse/backups
BACKUP_RETENTION_COUNT=7
S3_BACKUP_BUCKET=
S3_BACKUP_PREFIX=statuspulse
AWS_REGION=${var.aws_region}
AWS_ACCOUNT_ID=${var.aws_account_id}
AWS_INSTANCE_NAME=${var.instance_name}
ENV

cat >/etc/cron.d/statuspulse <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

*/5 * * * * ec2-user cd /opt/statuspulse && ./scripts/health-monitor.sh >> /opt/statuspulse/logs/health-monitor.log 2>&1
0 3 * * * ec2-user cd /opt/statuspulse && ./scripts/backup.sh >> /opt/statuspulse/logs/backup.log 2>&1
CRON

chmod 0644 /etc/cron.d/statuspulse

chown -R ec2-user:ec2-user /opt/statuspulse
EOF

  tags = {
    Name    = var.instance_name
    Project = var.project_name
    Role    = "web"
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
}

resource "aws_eip" "statuspulse" {
  domain = "vpc"

  tags = {
    Name    = "${var.project_name}-eip"
    Project = var.project_name
  }
}

resource "aws_eip_association" "statuspulse" {
  instance_id   = aws_instance.statuspulse.id
  allocation_id = aws_eip.statuspulse.id
}

output "instance_id" {
  value = aws_instance.statuspulse.id
}

output "elastic_ip" {
  value = aws_eip.statuspulse.public_ip
}

output "site_url" {
  value = local.public_base_url
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}

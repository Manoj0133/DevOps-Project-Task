variable "aws_region" {
  description = "AWS region for the StatusPulse stack."
  type        = string
  default     = "us-east-1"
}

variable "aws_account_id" {
  description = "AWS account ID used for the GitHub Actions role ARN."
  type        = string
  default     = "381492115031"
}

variable "project_name" {
  description = "Project tag prefix."
  type        = string
  default     = "statuspulse"
}

variable "instance_name" {
  description = "EC2 Name tag."
  type        = string
  default     = "statuspulse"
}

variable "instance_type" {
  description = "EC2 instance size."
  type        = string
  default     = "t3.micro"
}

variable "domain_name" {
  description = "Public DNS name used by Caddy."
  type        = string
  default     = "ak-info.online"
}

variable "caddy_email" {
  description = "Email address used for Let's Encrypt registration."
  type        = string
  default     = ""
}

variable "public_base_url" {
  description = "Public HTTPS URL for the deployed app."
  type        = string
  default     = ""
}

variable "github_repository" {
  description = "GitHub repository slug in owner/name form."
  type        = string
  default     = "ManojSelf/statuspulse"
}

variable "github_branch" {
  description = "Branch that GitHub Actions may deploy from."
  type        = string
  default     = "main"
}

variable "repository_clone_url" {
  description = "Public clone URL for bootstrapping the server checkout."
  type        = string
  default     = "https://github.com/Manoj0133/DevOps-Project-Task.git"
}

variable "ghcr_image" {
  description = "Container image repository in GHCR."
  type        = string
  default     = "ghcr.io/ManojSelf/statuspulse"
}

variable "do_token" {
  description = "DigitalOcean API token with read/write rights for droplets, firewalls and spaces."
  type        = string
  sensitive   = true
}

variable "do_region" {
  description = "Region where the resources will be provisioned."
  type        = string
  default     = "fra1"
}

variable "droplet_name" {
  description = "Name assigned to the monitoring droplet."
  type        = string
  default     = "pyron-monitor-stack"
}

variable "droplet_size" {
  description = "Size slug for the droplet."
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "ssh_key_fingerprint" {
  description = "Fingerprint of an existing SSH key configured in DigitalOcean."
  type        = string
}

variable "ssh_key_name" {
  description = "Name of the SSH key configured in DigitalOcean."
  type        = string
}

variable "environment" {
  description = "Environment label appended to resource names (e.g., staging, production)."
  type        = string
  default     = "production"
}

variable "spaces_bucket_name" {
  description = "Spaces bucket name where Loki will store data."
  type        = string
  default     = "pyron-monitor-stack"
}

variable "spaces_acl" {
  description = "Access control for the Spaces bucket."
  type        = string
  default     = "private"
}

variable "spaces_endpoint" {
  description = "Endpoint used to reach Spaces (e.g., https://fra1.digitaloceanspaces.com)."
  type        = string
  default     = "https://fra1.digitaloceanspaces.com"
}

variable "spaces_region" {
  description = "Region where the Spaces bucket lives (used by tfvars but also for sanity)."
  type        = string
  default     = "fra1"
}


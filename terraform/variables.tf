variable "do_token" {
  description = "DigitalOcean API token with read/write rights for droplets, firewalls and spaces."
  type        = string
  sensitive   = true
}

variable "do_region" {
  description = "Region where the resources will be provisioned."
  type        = string
  default     = "SGP1"
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

variable "do_project_id" {
  type = string
}

variable "spaces_access_id" {
  type      = string
  sensitive = true
}

variable "spaces_secret_key" {
  type      = string
  sensitive = true
}

variable "destroy" {
  type    = bool
  default = false
}

variable "working_vpc" {
  description = "UUID da VPC onde o monitoramento deve residir"
  type        = string
}

# Source ranges allowed to reach the in-cluster ingest ports (9090 remote_write,
# 3100 Loki push). This is per-ENVIRONMENT because each DOKS cluster lives in its
# own VPC with its own node and pod/CNI ranges, and DO does NOT SNAT pod->VPC
# egress to the node IP — so the firewall must admit the POD range too, not just
# the node range (see the firewall rules in main.tf for the full story).
#
# An EMPTY list means those ingest ports are not opened at all. Production ships
# with [] on purpose: its cluster is in a separate VPC and the network path has
# not been worked out yet, so there is nothing legitimate to admit and opening
# staging's ranges here would only drop prod-sourced traffic silently. Staging
# sets the two ranges it actually uses.
variable "cluster_cidrs" {
  description = "CIDRs allowed to reach the in-cluster ingest ports (9090/3100). Empty = ports stay closed."
  type        = list(string)
  default     = []
}


output "droplet_ip" {
  description = "Public IPv4 address of the monitoring droplet."
  value       = digitalocean_droplet.monitor.ipv4_address
}

output "droplet_ssh" {
  description = "SSH command to reach the droplet."
  value       = "ssh -i ~/.ssh/id_rsa root@${digitalocean_droplet.monitor.ipv4_address}"
}

output "ssh_fingerprint" {
  value = data.digitalocean_ssh_key.deploy.fingerprint
}


#output "spaces_bucket" {
#  description = "DigitalOcean Spaces bucket for Loki."
#  value = {
#    name     = digitalocean_spaces_bucket.loki.name
#    region   = digitalocean_spaces_bucket.loki.region
#    endpoint = var.spaces_endpoint
#  }
#}

#output "spaces_bucket_name" {
#  description = "Name of the Loki Spaces bucket."
#  value       = digitalocean_spaces_bucket.loki.name
#}

#output "spaces_bucket_region" {
#  description = "Region where the Loki bucket lives."
#  value       = digitalocean_spaces_bucket.loki.region
#}

#output "spaces_bucket_endpoint" {
#  description = "Endpoint used by Loki storage."
#  value       = var.spaces_endpoint
#}


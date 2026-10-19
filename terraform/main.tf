data "digitalocean_ssh_key" "deploy" {
  name = var.ssh_key_name
}

locals {
  normalized_env    = lower(trimspace(var.environment))
  droplet_full_name = "${var.droplet_name}-${local.normalized_env}"
  bucket_full_name  = "${var.spaces_bucket_name}-${local.normalized_env}"
}

resource "digitalocean_droplet" "monitor" {
  name   = local.droplet_full_name
  region = var.do_region
  size   = var.droplet_size
  image  = "ubuntu-24-04-x64"

  vpc_uuid = var.working_vpc

  ssh_keys = [
    data.digitalocean_ssh_key.deploy.id,
  ]

  tags = ["monitoring-stack", local.normalized_env]

  lifecycle {
    prevent_destroy = false
  }
}

resource "digitalocean_project_resources" "attach" {
  project = var.do_project_id
  resources = [
    digitalocean_droplet.monitor.urn,
    #digitalocean_spaces_bucket.loki.urn,
  ]
}


resource "digitalocean_firewall" "monitoring" {
  name        = "${var.droplet_name}-${local.normalized_env}-fw"
  droplet_ids = [digitalocean_droplet.monitor.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Loki push endpoint (:3100) and Prometheus remote_write receiver (:9090) —
  # the in-cluster shippers push here (Alloy for logs, a prometheus-agent for
  # metrics). These are PERMANENT observability plumbing, not tied to a single
  # burn: the cluster→droplet path needs them open.
  #
  # The source ranges come from var.cluster_cidrs and are per-ENVIRONMENT. Each
  # DOKS cluster lives in its own VPC: the ranges must cover BOTH the node range
  # (the VPC) AND the pod/CNI range, because DO does NOT SNAT pod→VPC egress to
  # the node IP — a pod's packets arrive with their POD IP. Verified on the live
  # STAGING cluster (2026-08-28): nodes 10.0.0.4/10.0.0.5, pods 10.105.x; without
  # the CNI range the receiver saw i/o timeouts as the firewall dropped the
  # pod-sourced traffic. 9090 is also the Prometheus UI, but that stays
  # SSH-tunnel-only; these rules admit in-cluster traffic only, nothing public.
  #
  # When cluster_cidrs is EMPTY these rules are not created at all, so the ports
  # stay closed rather than admitting one environment's ranges and dropping the
  # other's traffic silently. Both environments now set it (stage.tfvars and
  # prod.tfvars — prod opened in f278228), each to its OWN VPC + CNI ranges. See
  # var.cluster_cidrs and pyron-doks-iac platform/prod.tfvars.
  dynamic "inbound_rule" {
    for_each = length(var.cluster_cidrs) > 0 ? [1] : []
    content {
      protocol         = "tcp"
      port_range       = "3100"
      source_addresses = var.cluster_cidrs
    }
  }

  dynamic "inbound_rule" {
    for_each = length(var.cluster_cidrs) > 0 ? [1] : []
    content {
      protocol         = "tcp"
      port_range       = "9090"
      source_addresses = var.cluster_cidrs
    }
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "all"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "all"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

#resource "digitalocean_spaces_bucket" "loki" {
#  name   = local.bucket_full_name
#  region = var.spaces_region
#  acl    = var.spaces_acl
#}


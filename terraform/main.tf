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

  inbound_rule {
    protocol         = "tcp"
    port_range       = "3100"
    source_addresses = ["10.1.0.0/16"]
  }

  # Prometheus remote_write receiver (:9090) — the in-cluster ephemeral
  # prometheus-agent (see pyron-webhook k8s-ephemeral/prometheus-agent.yaml)
  # pushes per-pod webhook metrics here during the load-test burn, so the queue
  # depth / backlog aggregate exactly across 100+ pods (a single external
  # NodePort scrape can't).
  #
  # Two source ranges: 10.0.0.0/16 is the VPC (nodes), and 10.105.0.0/16 is the
  # DOKS POD/CNI network. DO does NOT SNAT pod→VPC egress to the node IP, so the
  # agent's packets arrive with their POD IP (10.105.x.x) — verified: without the
  # CNI range the receiver saw i/o timeouts (firewall dropped the pod-sourced
  # traffic). 9090 is also the Prometheus UI, but that stays SSH-tunnel-only;
  # these rules only admit in-cluster traffic, nothing public. Torn down with the
  # ephemeral agent.
  inbound_rule {
    protocol         = "tcp"
    port_range       = "9090"
    source_addresses = ["10.0.0.0/16", "10.105.0.0/16"]
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


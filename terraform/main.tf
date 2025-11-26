data "digitalocean_ssh_key" "deploy" {
  name = var.ssh_key_name
}

locals {
  normalized_env = lower(trimspace(var.environment))
  droplet_full_name = "${var.droplet_name}-${local.normalized_env}"
  bucket_full_name  = "${var.spaces_bucket_name}-${local.normalized_env}"
}

resource "digitalocean_droplet" "monitor" {
  name   = local.droplet_full_name
  region = var.do_region
  size   = var.droplet_size
  image  = "ubuntu-24-04-x64"

  ssh_keys = [
    data.digitalocean_ssh_key.deploy.id,
  ]

  tags = ["monitoring-stack", local.normalized_env]

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    apt-get update
    apt-get install -y \
      ca-certificates \
      curl \
      gnupg \
      lsb-release

    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    mkdir -p /opt/pyron-monitor-stack
    chown -R root:root /opt/pyron-monitor-stack
EOF
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
    port_range       = "3000"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "9090"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "3100"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "3200"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "9100"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "9093"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol         = "tcp"
    port_range       = "all"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol         = "udp"
    port_range       = "all"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

resource "digitalocean_spaces_bucket" "loki" {
  name   = local.bucket_full_name
  region = var.spaces_region
  acl    = var.spaces_acl
}


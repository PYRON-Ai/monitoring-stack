environment   = "staging"
working_vpc   = "4ba63b32-b79b-4969-9081-ecee8697bb84"
do_project_id = "4d35904f-7b87-4b19-9661-c521590ea17c"
do_region     = "sgp1"

droplet_name = "pyron-monitor-stack"
droplet_size = "s-2vcpu-4gb"

spaces_bucket_name = "monitor-terraform-states"
spaces_region      = "fra1"
spaces_endpoint    = "https://fra1.digitaloceanspaces.com"
ssh_key_name       = "monitor-stack-pipeline"

# In-cluster ingest allow-list (9090 remote_write, 3100 Loki push). Staging's
# DOKS cluster shares this VPC: 10.0.0.0/16 is the node/VPC range and
# 10.105.0.0/16 is the pod/CNI range (DO does not SNAT pod egress, so the pod
# range is required too). Verified on the live staging cluster 2026-08-28.
cluster_cidrs = ["10.0.0.0/16", "10.105.0.0/16"]

# false = CREATE/maintain the staging monitoring droplet (not a destroy run).
destroy = false


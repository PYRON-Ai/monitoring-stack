environment = "production"

# Production VPC + project — ISOLATED from staging. These are the production
# values from pyron-doks-iac/terraform/cluster/prod.tfvars (pyron-vpc-production
# / pyron-production), so the monitoring droplet lands in the same production
# network and project as the cluster it will eventually watch.
working_vpc   = "618f3ec4-335d-46de-a1d5-94b7f266d04f" # pyron-vpc-production
do_project_id = "b72e1059-d7ac-49ac-b845-d4f7b3deba4e" # pyron-production
do_region     = "sgp1"

droplet_name = "pyron-monitor-stack"
droplet_size = "s-2vcpu-4gb"

spaces_bucket_name = "monitor-terraform-states"
spaces_region      = "fra1"
spaces_endpoint    = "https://fra1.digitaloceanspaces.com"
ssh_key_name       = "monitor-stack-pipeline"

# In-cluster ingest allow-list — opens 9090 (remote_write) and 3100 (Loki push)
# to the production DOKS cluster.
#
# The production cluster is in a SEPARATE VPC (pyron-vpc-production) with its own
# ranges, DIFFERENT from staging's (staging was 10.0.0.0/16 + 10.105.0.0/16).
# Both ranges are required because DO does not SNAT pod→VPC egress to the node
# IP, so the agent's packets arrive with their POD IP — admitting only the node
# range would drop the remote_write (the i/o-timeout trap documented in main.tf).
#
# Verified on the live prod cluster (do-sgp1-pyron-doks-production):
#   nodes 10.1.0.3–10.1.0.9      → VPC range  10.1.0.0/16
#   pods  10.150.0.x/1.x/2.x     → CNI range  10.150.0.0/16
# (hostNetwork pods show the node IP in 10.1.0.x, already covered by the VPC range.)
cluster_cidrs = ["10.1.0.0/16", "10.150.0.0/16"]

# false = CREATE/maintain the production monitoring droplet (not a destroy run).
# NEVER flip this to true in production.
destroy = false

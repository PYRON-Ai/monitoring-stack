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

# In-cluster ingest allow-list — INTENTIONALLY EMPTY in production.
#
# The production DOKS cluster is in a SEPARATE VPC (pyron-vpc-production), with
# its own node and pod/CNI ranges that differ from staging's. Those ranges are
# not wired up here yet, and the cluster side does not ship metrics/logs to this
# droplet yet either — pyron-doks-iac/terraform/platform/prod.tfvars leaves
# enable_metrics_shipping / enable_log_shipping off for exactly this reason.
#
# So ports 9090/3100 stay CLOSED on the prod droplet for now (empty list => the
# dynamic firewall rules in main.tf are not created). Opening staging's ranges
# here would admit nothing real and only risk dropping prod-sourced traffic
# silently once the agent is deployed. When the prod cluster→droplet network
# path is worked out, set this to the prod VPC node range + pod/CNI range
# (verify the pod range on the live prod cluster, as was done for staging).
cluster_cidrs = []

# false = CREATE/maintain the production monitoring droplet (not a destroy run).
# NEVER flip this to true in production.
destroy = false

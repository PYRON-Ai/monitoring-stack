environment   = "production"
working_vpc   = "618f3ec4-335d-46de-a1d5-94b7f266d04f"
do_project_id = "b72e1059-d7ac-49ac-b845-d4f7b3deba4e"
do_region     = "SGP1"

droplet_name = "pyron-monitor-stack"
droplet_size = "s-2vcpu-4gb"

spaces_bucket_name = "monitor-terraform-states"
spaces_region      = "fra1"
spaces_endpoint    = "https://fra1.digitaloceanspaces.com"
ssh_key_name       = "monitor-stack-pipeline"

destroy = false


environment   = "staging"
working_vpc   = "4ba63b32-b79b-4969-9081-ecee8697bb84"
do_project_id = "4d35904f-7b87-4b19-9661-c521590ea17c"
do_region     = "SGP1"

droplet_name = "pyron-monitor-stack"
droplet_size = "s-2vcpu-4gb"

spaces_bucket_name = "monitor-terraform-states"
spaces_bucket_key  = "staging/terraform.tfstate"
spaces_region      = "fra1"
spaces_endpoint    = "https://sgp1.digitaloceanspaces.com"
ssh_key_name       = "monitor-stack-pipeline"

destroy = false


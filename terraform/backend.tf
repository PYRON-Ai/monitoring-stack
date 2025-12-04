terraform {
  backend "s3" {
    endpoint                    = "https://fra1.digitaloceanspaces.com"
    bucket                      = "pyron-monitor-stack-tfstate"
    key                         = "staging/terraform.tfstate"
    region                      = "us-east-1"

    force_path_style            = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
  }
}

terraform {
  backend "s3" {
    endpoints = {
      s3 = "https://sgp1.digitaloceanspaces.com"
    }

    bucket   = "pyron-monitor-stack-tfstate"
    key      = "staging/terraform.tfstate"
    region   = "sgp1"
    force_path_style            = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
  }
}

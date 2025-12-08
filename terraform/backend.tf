terraform {
  backend "s3" {
    endpoint                    = "https://sgp1.digitaloceanspaces.com"
    bucket                      = var.spaces_bucket_name
    key                         = var.spaces_bucket_key
    region                      = "sgp1"
    force_path_style            = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
  }
}

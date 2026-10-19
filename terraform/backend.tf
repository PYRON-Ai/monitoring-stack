terraform {
  backend "s3" {
    endpoint = "https://sgp1.digitaloceanspaces.com"
    bucket   = "monitor-terraform-states"
    # NO `key` here on purpose — it is passed per environment at init time via
    # `-backend-config="key=<env>/terraform.tfstate"`, so staging and production
    # keep SEPARATE state files in the same bucket and can never clobber each
    # other. Each pipeline's "Terraform init" step supplies its own key:
    #   staging    → staging/terraform.tfstate     (stage-deploy.yml)
    #   production → production/terraform.tfstate   (prod-deploy.yml)
    # A bare `terraform init` with no -backend-config will now PROMPT for the
    # key rather than silently defaulting to staging's state.
    region                      = "sgp1"
    force_path_style            = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
  }
}

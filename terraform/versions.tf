terraform {
  required_version = ">= 1.5"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }
}

# Credentials come from ~/.oci/config (created when you add an API key in the console).
provider "oci" {
  config_file_profile = var.oci_profile
  region              = var.region
}

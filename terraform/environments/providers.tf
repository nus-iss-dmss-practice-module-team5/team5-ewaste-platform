terraform {
  required_version = ">= 1.8.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "azurerm" {
    # Dynamically configured by GitHub Actions CD.
    # Example state keys: dev.tfstate, stg.tfstate, prod.tfstate
  }
}

provider "azurerm" {
  features {
    key_vault {
      # Sprint 1 baseline favors clean teardown/recreation for the academic environment.
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = false
    }
  }
}

locals {
  name_prefix = "ewaste-${var.environment}"

  common_tags = {
    Project     = "Responsible E-Waste Chain-of-Custody"
    Environment = var.environment
    ManagedBy   = "Terraform"
    Course      = "SWE5006"
    Sprint      = "Sprint-1"
  }
}

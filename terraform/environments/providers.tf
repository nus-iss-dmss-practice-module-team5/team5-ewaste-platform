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
  features {}
}

locals {
  name_prefix = "ewaste-${var.environment}"
  # Keep existing tfvars usable while callers adopt the analytics name.
  analytics_signing_secret = var.analytics_signing_secret != null ? var.analytics_signing_secret : var.matcher_signing_secret

  common_tags = {
    Project     = "Responsible E-Waste Chain-of-Custody"
    Environment = var.environment
    ManagedBy   = "Terraform"
    Course      = "SWE5006"
    Sprint      = "Sprint-1"
  }
}

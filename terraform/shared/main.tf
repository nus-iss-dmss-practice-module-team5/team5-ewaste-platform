terraform {
  required_version = ">= 1.8.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }

  backend "azurerm" {
    # Dynamically configured by CI/CD.
    # Recommended state key for this tier: shared.tfstate
  }
}

provider "azurerm" {
  features {}
}

# Persistent shared resource group.
resource "azurerm_resource_group" "shared" {
  name     = "rg-ewaste-shared"
  location = "southeastasia"

  tags = {
    Project   = "Responsible E-Waste Chain-of-Custody"
    ManagedBy = "Terraform"
    Tier      = "Shared"
    Course    = "SWE5006"
  }
}

# Centralized Azure Container Registry.
# Premium is required for Private Link. Public access and admin credentials are disabled.
resource "azurerm_container_registry" "acr" {
  # checkov:skip=CKV_AZURE_164:Docker Content Trust cannot be enabled on new ACR registries after 2026-05-31; release images are signed and verified with Cosign in GitHub Actions instead.
  name                          = "acrewasteplatform"
  resource_group_name           = azurerm_resource_group.shared.name
  location                      = azurerm_resource_group.shared.location
  sku                           = "Premium"
  admin_enabled                 = false
  anonymous_pull_enabled        = false
  public_network_access_enabled = false
  network_rule_bypass_option    = "AzureServices"

  network_rule_set {
    default_action = "Deny"
  }

  tags = {
    Project = "Responsible E-Waste Chain-of-Custody"
    Tier    = "Shared"
  }
}

# Centralized Log Analytics Workspace for Azure Monitor telemetry.
resource "azurerm_log_analytics_workspace" "logs" {
  name                = "log-ewaste-centralized"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = {
    Project = "Responsible E-Waste Chain-of-Custody"
    Tier    = "Shared"
  }
}

output "acr_id" {
  value       = azurerm_container_registry.acr.id
  description = "Shared ACR resource ID for RBAC bindings and environment private endpoints."
}

output "acr_login_server" {
  value       = azurerm_container_registry.acr.login_server
  description = "Shared ACR login server URL."
}

output "log_analytics_workspace_id" {
  value       = azurerm_log_analytics_workspace.logs.id
  description = "Centralized Log Analytics Workspace resource ID."
}

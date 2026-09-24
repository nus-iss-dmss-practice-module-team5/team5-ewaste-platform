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
  location = "malaysiawest"

  tags = {
    Project   = "Responsible E-Waste Chain-of-Custody"
    ManagedBy = "Terraform"
    Tier      = "Shared"
    Course    = "SWE5006"
  }
}

# Centralized Azure Container Registry.
# Premium SKU required for Private Link. Firewall default-Deny with zero standing IP rules.
# CI jobs ephemerally whitelist the GitHub runner IP for docker push and remove it post-job.
# ACA runtime pulls via per-environment private endpoints + UAMI AcrPull.
resource "azurerm_container_registry" "acr" {
  # checkov:skip=CKV_AZURE_139:Public network enabled with default-Deny firewall and no standing IP rules. GitHub runner IPs are ephemerally whitelisted during CI builds and removed post-job. ACR Tasks unavailable on this subscription.
  name                          = "acrewasteplatform"
  resource_group_name           = azurerm_resource_group.shared.name
  location                      = "japaneast"
  sku                           = "Premium"
  admin_enabled                 = false
  anonymous_pull_enabled        = false
  public_network_access_enabled = true
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

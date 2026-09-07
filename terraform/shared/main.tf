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
# Admin credentials remain disabled; runtime pulls use managed identity.
resource "azurerm_container_registry" "acr" {
  name                = "acrewasteplatform"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  sku                 = "Standard"
  admin_enabled       = false

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
  description = "Shared ACR resource ID for RBAC bindings."
}

output "acr_login_server" {
  value       = azurerm_container_registry.acr.login_server
  description = "Shared ACR login server URL."
}

output "log_analytics_workspace_id" {
  value       = azurerm_log_analytics_workspace.logs.id
  description = "Centralized Log Analytics Workspace resource ID."
}

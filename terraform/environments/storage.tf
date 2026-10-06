# ============================================================================
# AZURE BLOB STORAGE FOR PHYSICAL VERIFICATION EVIDENCE (DECISION D2)
# ============================================================================
# Dedicated private Azure Blob Storage account supporting physical verification
# and treatment evidence (weighbridge tickets, destruction certificates, photos).
# - Account Tier: Standard_LRS (lowest approved cost tier satisfying 11 9's durability).
# - Access Tier: Hot (optimized for active verification workflows).
# - Network: Zero public internet access; strictly isolated via Azure Private Link.
# - Authentication: Shared access keys enabled for IaC provider management; runtime
#   workload strictly authenticates via secretless Azure AD Managed Identity.
# - Retention: 7-day soft delete and blob versioning enabled for compliance audit trail.
# ============================================================================

resource "azurerm_storage_account" "evidence" {
  # checkov:skip=CKV_AZURE_144:LRS replication approved in Decision D2 for single-region academic MVP cost control.
  # checkov:skip=CKV_AZURE_166:Customer Managed Keys (CMK) disabled for academic MVP cost control; uses Microsoft-managed keys.
  # checkov:skip=CKV_AZURE_206:Advanced Threat Protection disabled for academic MVP cost control.
  # checkov:skip=CKV_AZURE_33:Storage logging for queues not applicable to blob-only evidence store.
  name                              = "stgewaste${var.environment}"
  resource_group_name               = azurerm_resource_group.env_rg.name
  location                          = azurerm_resource_group.env_rg.location
  account_tier                      = "Standard"
  account_replication_type          = "LRS"
  account_kind                      = "StorageV2"
  https_traffic_only_enabled        = true
  min_tls_version                   = "TLS1_2"
  public_network_access_enabled     = false
  allow_nested_items_to_be_public   = false
  shared_access_key_enabled         = true # Required for Terraform AzureRM provider management; application strictly uses secretless Managed Identity
  default_to_oauth_authentication   = true
  infrastructure_encryption_enabled = true

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 7
    }

    container_delete_retention_policy {
      days = 7
    }
  }

  tags = local.common_tags
}

resource "azurerm_storage_container" "evidence_private" {
  name                  = "evidence-private"
  storage_account_name  = azurerm_storage_account.evidence.name
  container_access_type = "private"

  depends_on = [
    azurerm_role_assignment.sp_storage_blob_data_contributor
  ]
}

# ============================================================================
# PRIVATE LINK & PRIVATE DNS INTEGRATION
# ============================================================================

resource "azurerm_private_dns_zone" "blob_dns" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.env_rg.name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob_dns_link" {
  name                  = "vnetlink-blob"
  private_dns_zone_name = azurerm_private_dns_zone.blob_dns.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  resource_group_name   = azurerm_resource_group.env_rg.name
}

resource "azurerm_private_endpoint" "storage_pe" {
  name                = "pe-stgewaste-${var.environment}"
  location            = azurerm_resource_group.env_rg.location
  resource_group_name = azurerm_resource_group.env_rg.name
  subnet_id           = azurerm_subnet.private_endpoints_subnet.id
  tags                = local.common_tags

  private_service_connection {
    name                           = "psc-stgewaste-${var.environment}"
    private_connection_resource_id = azurerm_storage_account.evidence.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdz-group-blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob_dns.id]
  }
}

# ============================================================================
# RBAC: SECRETLESS AZURE AD MANAGED IDENTITY ACCESS
# ============================================================================

# Grant ACA API User-Assigned Managed Identity read/write access to evidence blobs
resource "azurerm_role_assignment" "storage_blob_data_contributor" {
  scope                = azurerm_storage_account.evidence.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.aca_identity.principal_id
}

# Grant Deployment Service Principal access for pipeline validation
resource "azurerm_role_assignment" "sp_storage_blob_data_contributor" {
  scope                = azurerm_storage_account.evidence.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Grant Self-Hosted Runner VM access to Blob Storage when runner is enabled
resource "azurerm_role_assignment" "runner_storage_blob_data_contributor" {
  count                = var.enable_self_hosted_runner ? 1 : 0
  scope                = azurerm_storage_account.evidence.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.runner_identity[0].principal_id
}

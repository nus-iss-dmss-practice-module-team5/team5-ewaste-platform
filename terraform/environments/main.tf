# ============================================================================
# 1. READ PERSISTENT SHARED INFRASTRUCTURE
# ============================================================================

data "azurerm_container_registry" "shared_acr" {
  name                = var.shared_acr_name
  resource_group_name = var.shared_rg_name
}

data "azurerm_log_analytics_workspace" "shared_logs" {
  name                = var.shared_log_analytics_name
  resource_group_name = var.shared_rg_name
}

# ============================================================================
# 2. ENVIRONMENT RESOURCE GROUP
# ============================================================================

resource "azurerm_resource_group" "env_rg" {
  name     = "rg-${local.name_prefix}"
  location = var.location
  tags     = local.common_tags
}

# ============================================================================
# 3. NETWORK BOUNDARY, ACA INTEGRATION & PRIVATE ENDPOINTS
# ============================================================================

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${local.name_prefix}"
  location            = azurerm_resource_group.env_rg.location
  resource_group_name = azurerm_resource_group.env_rg.name
  address_space       = ["10.0.0.0/16"]
  tags                = local.common_tags
}

resource "azurerm_subnet" "mysql_subnet" {
  name                 = "snet-mysql"
  resource_group_name  = azurerm_resource_group.env_rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]
  service_endpoints    = ["Microsoft.Storage"]

  delegation {
    name = "mysql-delegation"

    service_delegation {
      name = "Microsoft.DBforMySQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action"
      ]
    }
  }
}

# Dedicated /21 subnet required by the Consumption-only ACA environment model
# used by the pinned AzureRM 3.x provider baseline.
resource "azurerm_subnet" "aca_subnet" {
  name                 = "snet-aca"
  resource_group_name  = azurerm_resource_group.env_rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.8.0/21"]

  delegation {
    name = "aca-delegation"

    service_delegation {
      name = "Microsoft.App/environments"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action"
      ]
    }
  }
}

# Private endpoints must use a subnet separate from the delegated MySQL and ACA subnets.
resource "azurerm_subnet" "private_endpoints_subnet" {
  name                                      = "snet-private-endpoints"
  resource_group_name                       = azurerm_resource_group.env_rg.name
  virtual_network_name                      = azurerm_virtual_network.vnet.name
  address_prefixes                          = ["10.0.3.0/24"]
  private_endpoint_network_policies         = "Disabled"
}

# Private DNS zone used by the private MySQL Flexible Server.
resource "azurerm_private_dns_zone" "mysql_dns" {
  name                = "${local.name_prefix}.mysql.database.azure.com"
  resource_group_name = azurerm_resource_group.env_rg.name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "mysql_dns_link" {
  name                  = "vnetlink-mysql"
  private_dns_zone_name = azurerm_private_dns_zone.mysql_dns.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  resource_group_name   = azurerm_resource_group.env_rg.name
}

resource "azurerm_private_dns_zone" "key_vault_dns" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.env_rg.name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "key_vault_dns_link" {
  name                  = "vnetlink-key-vault"
  private_dns_zone_name = azurerm_private_dns_zone.key_vault_dns.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  resource_group_name   = azurerm_resource_group.env_rg.name
}

resource "azurerm_private_dns_zone" "redis_dns" {
  name                = "privatelink.redis.cache.windows.net"
  resource_group_name = azurerm_resource_group.env_rg.name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis_dns_link" {
  name                  = "vnetlink-redis"
  private_dns_zone_name = azurerm_private_dns_zone.redis_dns.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  resource_group_name   = azurerm_resource_group.env_rg.name
}

resource "azurerm_private_dns_zone" "acr_dns" {
  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.env_rg.name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr_dns_link" {
  name                  = "vnetlink-acr"
  private_dns_zone_name = azurerm_private_dns_zone.acr_dns.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  resource_group_name   = azurerm_resource_group.env_rg.name
}

# Each isolated runtime environment receives a private endpoint to the shared ACR.
resource "azurerm_private_endpoint" "acr" {
  name                = "pe-acr-${local.name_prefix}"
  location            = azurerm_resource_group.env_rg.location
  resource_group_name = azurerm_resource_group.env_rg.name
  subnet_id           = azurerm_subnet.private_endpoints_subnet.id
  tags                = local.common_tags

  private_service_connection {
    name                           = "psc-acr-${local.name_prefix}"
    private_connection_resource_id = data.azurerm_container_registry.shared_acr.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr_dns.id]
  }
}

# ============================================================================
# 4. ENVIRONMENT KEY VAULT & MANAGED IDENTITY
# ============================================================================

resource "azurerm_key_vault" "kv" {
  # checkov:skip=CKV_AZURE_110:Sprint 1 baseline permits clean environment teardown/recreation.
  name                          = "kv-${local.name_prefix}"
  location                      = azurerm_resource_group.env_rg.location
  resource_group_name           = azurerm_resource_group.env_rg.name
  tenant_id                     = var.tenant_id
  sku_name                      = "standard"
  soft_delete_retention_days    = 7
  purge_protection_enabled      = false
  enable_rbac_authorization     = true
  public_network_access_enabled = false
  tags                          = local.common_tags

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }
}

resource "azurerm_private_endpoint" "key_vault" {
  name                = "pe-kv-${local.name_prefix}"
  location            = azurerm_resource_group.env_rg.location
  resource_group_name = azurerm_resource_group.env_rg.name
  subnet_id           = azurerm_subnet.private_endpoints_subnet.id
  tags                = local.common_tags

  private_service_connection {
    name                           = "psc-kv-${local.name_prefix}"
    private_connection_resource_id = azurerm_key_vault.kv.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.key_vault_dns.id]
  }
}

resource "azurerm_user_assigned_identity" "aca_identity" {
  name                = "id-${local.name_prefix}"
  location            = azurerm_resource_group.env_rg.location
  resource_group_name = azurerm_resource_group.env_rg.name
  tags                = local.common_tags
}

resource "azurerm_role_assignment" "kv_secrets_user" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.aca_identity.principal_id
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = data.azurerm_container_registry.shared_acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.aca_identity.principal_id
}

# ============================================================================
# 5. DATA TIER: MYSQL FLEXIBLE SERVER & REDIS
# ============================================================================

resource "azurerm_mysql_flexible_server" "db" {
  # checkov:skip=CKV_AZURE_42:Auto-grow disabled in Sprint 1 baseline for student cost control.
  # checkov:skip=CKV_AZURE_98:Geo-redundant backup disabled for single-region academic MVP.
  name                   = "mysql-${local.name_prefix}"
  resource_group_name    = azurerm_resource_group.env_rg.name
  location               = azurerm_resource_group.env_rg.location
  administrator_login    = var.db_admin_username
  administrator_password = var.db_admin_password

  sku_name = "B_Standard_B1ms"
  version  = "8.0.21"

  delegated_subnet_id = azurerm_subnet.mysql_subnet.id
  private_dns_zone_id = azurerm_private_dns_zone.mysql_dns.id

  storage {
    size_gb           = 20
    auto_grow_enabled = false
  }

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false
  tags                         = local.common_tags

  lifecycle {
    ignore_changes = [
      zone,
      high_availability[0].standby_availability_zone
    ]
  }

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.mysql_dns_link
  ]
}

resource "azurerm_mysql_flexible_database" "ewastedb" {
  name                = "ewastedb"
  resource_group_name = azurerm_resource_group.env_rg.name
  server_name         = azurerm_mysql_flexible_server.db.name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
}

resource "azurerm_redis_cache" "redis" {
  name                          = "redis-${local.name_prefix}"
  location                      = azurerm_resource_group.env_rg.location
  resource_group_name           = azurerm_resource_group.env_rg.name
  capacity                      = 0
  family                        = "C"
  sku_name                      = "Basic"
  non_ssl_port_enabled          = false
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false
  tags                          = local.common_tags
}

resource "azurerm_private_endpoint" "redis" {
  name                = "pe-redis-${local.name_prefix}"
  location            = azurerm_resource_group.env_rg.location
  resource_group_name = azurerm_resource_group.env_rg.name
  subnet_id           = azurerm_subnet.private_endpoints_subnet.id
  tags                = local.common_tags

  private_service_connection {
    name                           = "psc-redis-${local.name_prefix}"
    private_connection_resource_id = azurerm_redis_cache.redis.id
    subresource_names              = ["redisCache"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.redis_dns.id]
  }
}

# ============================================================================
# 6. COMPUTE: AZURE CONTAINER APPS
# ============================================================================

resource "azurerm_container_app_environment" "aca_env" {
  name                       = "cae-${local.name_prefix}"
  location                   = azurerm_resource_group.env_rg.location
  resource_group_name        = azurerm_resource_group.env_rg.name
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.shared_logs.id
  infrastructure_subnet_id   = azurerm_subnet.aca_subnet.id
  tags                       = local.common_tags

  lifecycle {
    ignore_changes = [
      infrastructure_resource_group_name
    ]
  }
}

# # 6.1 Backend API / workflow Container App.
# resource "azurerm_container_app" "api" {
#   name                         = "aca-${local.name_prefix}-api"
#   container_app_environment_id = azurerm_container_app_environment.aca_env.id
#   resource_group_name          = azurerm_resource_group.env_rg.name
#   revision_mode                = "Single"
#   tags                         = local.common_tags
#
#   identity {
#     type         = "UserAssigned"
#     identity_ids = [azurerm_user_assigned_identity.aca_identity.id]
#   }
#
#   registry {
#     server   = data.azurerm_container_registry.shared_acr.login_server
#     identity = azurerm_user_assigned_identity.aca_identity.id
#   }
#
#   # Native ACA secrets (encrypted at rest by Azure)
#   secret {
#     name  = "db-password"
#     value = random_password.db_password.result
#   }
#
#   secret {
#     name  = "redis-conn"
#     value = azurerm_redis_cache.redis.primary_connection_string
#   }
#
#   template {
#     min_replicas = 1
#     max_replicas = 2
#
#     container {
#       name   = "auth-workflow-api"
#       image  = var.image_digest
#       cpu    = 0.5
#       memory = "1.0Gi"
#
#       env {
#         name  = "APP_ENV"
#         value = var.environment
#       }
#
#       env {
#         name  = "DB_HOST"
#         value = azurerm_mysql_flexible_server.db.fqdn
#       }
#
#       env {
#         name  = "DB_USER"
#         value = var.db_admin_username
#       }
#
#       env {
#         name        = "DB_PASSWORD"
#         secret_name = "db-password"
#       }
#
#       env {
#         name        = "REDIS_CONN"
#         secret_name = "redis-conn"
#       }
#     }
#   }
#
#   ingress {
#     external_enabled = true
#     target_port      = 80
#     transport        = "auto"
#
#     traffic_weight {
#       percentage      = 100
#       latest_revision = true
#     }
#   }
#
#   lifecycle {
#     ignore_changes = [
#       template[0].container[0].image,
#       ingress[0].target_port
#     ]
#   }
#
#   depends_on = [
#     azurerm_role_assignment.kv_secrets_user,
#     azurerm_role_assignment.acr_pull,
#     azurerm_private_endpoint.acr,
#     azurerm_private_endpoint.key_vault,
#     azurerm_private_endpoint.redis
#   ]
# }
#
# # 6.2 Frontend UI (Next.js) Container App.
# resource "azurerm_container_app" "ui" {
#   name                         = "aca-${local.name_prefix}-ui"
#   container_app_environment_id = azurerm_container_app_environment.aca_env.id
#   resource_group_name          = azurerm_resource_group.env_rg.name
#   revision_mode                = "Single"
#   tags                         = local.common_tags
#
#   identity {
#     type         = "UserAssigned"
#     identity_ids = [azurerm_user_assigned_identity.aca_identity.id]
#   }
#
#   registry {
#     server   = data.azurerm_container_registry.shared_acr.login_server
#     identity = azurerm_user_assigned_identity.aca_identity.id
#   }
#
#   template {
#     min_replicas = 1
#     max_replicas = 2
#
#     container {
#       name   = "ewaste-frontend-ui"
#       image  = var.ui_image_digest
#       cpu    = 0.5
#       memory = "1.0Gi"
#
#       env {
#         name  = "APP_ENV"
#         value = var.environment
#       }
#
#       env {
#         name  = "NEXT_PUBLIC_API_URL"
#         value = "https://${azurerm_container_app.api.latest_revision_fqdn}"
#       }
#     }
#   }
#
#   ingress {
#     external_enabled = true
#     target_port      = 80
#     transport        = "auto"
#
#     traffic_weight {
#       percentage      = 100
#       latest_revision = true
#     }
#   }
#
#   lifecycle {
#     ignore_changes = [
#       template[0].container[0].image,
#       ingress[0].target_port
#     ]
#   }
#
#   depends_on = [
#     azurerm_role_assignment.acr_pull,
#     azurerm_private_endpoint.acr
#   ]
# }

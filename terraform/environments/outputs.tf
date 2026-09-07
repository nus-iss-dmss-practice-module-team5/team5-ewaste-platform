output "resource_group_name" {
  value       = azurerm_resource_group.env_rg.name
  description = "Target environment resource group."
}

output "aca_api_fqdn" {
  value       = azurerm_container_app.api.latest_revision_fqdn
  description = "Public FQDN of the deployed Container App."
}

output "mysql_fqdn" {
  value       = azurerm_mysql_flexible_server.db.fqdn
  description = "Private FQDN for internal MySQL connectivity."
}

output "mysql_database_name" {
  value       = azurerm_mysql_flexible_server_database.ewastedb.name
  description = "Operational database name for Liquibase schema targeting."
}

output "mysql_admin_username" {
  value       = var.db_admin_username
  description = "Administrator username for MySQL Flexible Server."
}

output "mysql_jdbc_url" {
  value       = "jdbc:mysql://${azurerm_mysql_flexible_server.db.fqdn}:3306/${azurerm_mysql_flexible_server_database.ewastedb.name}?useSSL=true&requireSSL=true"
  description = "Formatted JDBC URL consumed by Liquibase migrations in CI/CD."
}

output "managed_identity_client_id" {
  value       = azurerm_user_assigned_identity.aca_identity.client_id
  description = "Client ID of the user-assigned managed identity."
}

output "key_vault_uri" {
  value       = azurerm_key_vault.kv.vault_uri
  description = "Target environment Key Vault URI."
}

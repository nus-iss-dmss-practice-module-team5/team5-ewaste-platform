output "resource_group_name" {
  value       = azurerm_resource_group.env_rg.name
  description = "Target environment resource group."
}

output "mysql_fqdn" {
  value       = azurerm_mysql_flexible_server.db.fqdn
  description = "Private FQDN for internal MySQL connectivity."
}

output "mysql_database_name" {
  value       = azurerm_mysql_flexible_database.ewastedb.name
  description = "Operational database name for Liquibase schema targeting."
}

output "mysql_admin_username" {
  value       = var.db_admin_username
  description = "Administrator username for MySQL Flexible Server."
}

output "mysql_jdbc_url" {
  value       = "jdbc:mysql://${azurerm_mysql_flexible_server.db.fqdn}:3306/${azurerm_mysql_flexible_database.ewastedb.name}?useSSL=true&requireSSL=true"
  description = "Formatted JDBC URL consumed by Liquibase migrations in CI/CD."
}

output "mysql_admin_password" {
  value       = var.db_admin_password
  sensitive   = true
  description = "Administrator password for MySQL Flexible Server."
}

output "managed_identity_client_id" {
  value       = azurerm_user_assigned_identity.aca_identity.client_id
  description = "Client ID of the user-assigned managed identity."
}

output "aca_identity_id" {
  value       = azurerm_user_assigned_identity.aca_identity.id
  description = "Resource ID of the user-assigned managed identity for ACA."
}

output "key_vault_uri" {
  value       = azurerm_key_vault.kv.vault_uri
  description = "Target environment Key Vault URI."
}

output "acr_private_endpoint_ip" {
  value       = azurerm_private_endpoint.acr.private_service_connection[0].private_ip_address
  description = "Private IP allocated to the shared ACR endpoint in this environment."
}

output "key_vault_private_endpoint_ip" {
  value       = azurerm_private_endpoint.key_vault.private_service_connection[0].private_ip_address
  description = "Private IP allocated to the environment Key Vault endpoint."
}

output "redis_private_endpoint_ip" {
  value       = azurerm_private_endpoint.redis.private_service_connection[0].private_ip_address
  description = "Private IP allocated to the environment Redis endpoint."
}

output "redis_primary_access_key" {
  value       = azurerm_redis_cache.redis.primary_access_key
  sensitive   = true
  description = "Primary access key for Azure Cache for Redis."
}

output "acr_login_server" {
  value       = data.azurerm_container_registry.shared_acr.login_server
  description = "Login server for the shared Azure Container Registry."
}

output "kafka_bootstrap_servers" {
  value       = "${azurerm_eventhub_namespace.kafka.name}.servicebus.windows.net:9093"
  description = "Kafka bootstrap broker endpoint for Go relay and Python matching consumers."
}

output "kafka_primary_connection_string" {
  value       = azurerm_eventhub_namespace_authorization_rule.app_auth.primary_connection_string
  sensitive   = true
  description = "SASL/PLAIN connection string for Kafka producers and consumers."
}

output "kafka_topics" {
  value       = [for t in azurerm_eventhub.topics : t.name]
  description = "List of provisioned canonical Kafka topics."
}

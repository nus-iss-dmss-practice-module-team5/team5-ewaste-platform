variable "environment" {
  type        = string
  default     = "dev"
  description = "Target deployment environment: dev, stg, or prod."

  validation {
    condition     = contains(["dev", "stg", "prod"], var.environment)
    error_message = "environment must be one of: dev, stg, prod."
  }
}

variable "location" {
  type        = string
  default     = "southeastasia"
  description = "Primary Azure region."
}

variable "tenant_id" {
  type        = string
  description = "Microsoft Entra ID tenant GUID."
}

variable "shared_rg_name" {
  type        = string
  default     = "rg-ewaste-shared"
  description = "Name of the shared persistent resource group."
}

variable "shared_acr_name" {
  type        = string
  default     = "acrewasteplatform"
  description = "Name of the shared Azure Container Registry."
}

variable "shared_log_analytics_name" {
  type        = string
  default     = "log-ewaste-centralized"
  description = "Name of the shared Log Analytics Workspace."
}

variable "db_admin_username" {
  type        = string
  default     = "ewasteadmin"
  description = "Administrator login for MySQL Flexible Server."
}

variable "image_digest" {
  type        = string
  default     = "mcr.microsoft.com/azuredocs/aci-helloworld:latest"
  description = "Immutable API/workflow image digest from ACR, or initial bootstrap image."
}

variable "ui_image_digest" {
  type        = string
  default     = "mcr.microsoft.com/azuredocs/aci-helloworld:latest"
  description = "Immutable Next.js frontend image digest from ACR, or initial bootstrap image."
}

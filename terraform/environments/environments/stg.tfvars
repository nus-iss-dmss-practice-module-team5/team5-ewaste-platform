environment                   = "stg"
location                      = "malaysiawest"
shared_rg_name                = "rg-ewaste-shared"
shared_acr_name               = "acrewasteplatform"
shared_log_analytics_name     = "log-ewaste-centralized"
tenant_id                     = "00000000-0000-0000-0000-000000000000" # Replace/inject in pipeline
db_admin_username             = "ewasteadmin"
auth_access_secret            = "default-dev-access-secret-minimum-32-chars-long"
auth_refresh_secret           = "default-dev-refresh-secret-minimum-32-chars-long"
auth_refresh_hash_secret      = "default-dev-refresh-hash-secret-32-chars"
# Supply analytics_service_token through an untracked local .tfvars file or -var/TF_VAR_analytics_service_token.
# image_digest should normally be supplied by CI/CD after the ACR image is built.

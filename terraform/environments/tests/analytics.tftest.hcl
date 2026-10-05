# Uses Terraform 1.8 mock providers only: no Azure calls or real credentials.
mock_provider "azurerm" {
  mock_data "azurerm_container_registry" {
    defaults = {
      id           = "/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/test/providers/Microsoft.ContainerRegistry/registries/testregistry"
      login_server = "testregistry.azurecr.io"
    }
  }
  mock_data "azurerm_log_analytics_workspace" {
    defaults = {
      id = "/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/test/providers/Microsoft.OperationalInsights/workspaces/test"
    }
  }
}
mock_provider "random" {}
mock_provider "tls" {}

variables {
  tenant_id                 = "00000000-0000-4000-8000-000000000001"
  db_admin_password         = "Local-test-database-123!"
  auth_access_secret        = "local-test-access-secret-at-least-32-characters"
  auth_refresh_secret       = "local-test-refresh-secret-at-least-32-characters"
  auth_refresh_hash_secret  = "local-test-refresh-hash-at-least-32-characters"
  analytics_signing_secret  = "local-test-analytics-secret-at-least-32-characters"
  enable_self_hosted_runner = false
}

run "analytics_configuration_survives_iac" {
  command = plan

  assert {
    condition = alltrue([
      for app in [azurerm_container_app.api, azurerm_container_app.analytics] :
      one([for s in app.secret : s.value if s.name == "matching-signing-key"]) == var.analytics_signing_secret
    ])
    error_message = "API and worker must retain the same dedicated analytics signing secret."
  }

  assert {
    condition = alltrue([
      for key, value in {
        EWASTE_MATCHING_ENABLED  = "true"
        EWASTE_MATCHING_ISSUER   = "ewaste-matching-dev"
        EWASTE_MATCHING_AUDIENCE = "ewaste-matching-api-dev"
        EWASTE_KAFKA_BATCH_SIZE  = "1"
      } : one([for e in azurerm_container_app.api.template[0].container[0].env : e.value if e.name == key]) == value
    ])
    error_message = "IaC must keep the matching facade enabled and preserve CD's issuer, audience and publisher settings."
  }

  assert {
    condition = alltrue([
      for key in [
        "ANALYTICS_FACADE_URL", "ANALYTICS_LOCAL_TEST", "ANALYTICS_TOPIC", "ANALYTICS_DLQ_TOPIC",
        "ANALYTICS_GROUP_ID", "ANALYTICS_OFFSET_RESET", "ANALYTICS_TOKEN_ISSUER", "ANALYTICS_TOKEN_AUDIENCE",
        "ANALYTICS_HTTP_TIMEOUT_SECONDS", "ANALYTICS_MAX_RESPONSE_BYTES", "ANALYTICS_MAX_RECORD_BYTES",
        "ANALYTICS_DELIVERY_TIMEOUT_SECONDS", "ANALYTICS_RETRY_BASE_SECONDS", "ANALYTICS_RETRY_MAX_SECONDS",
        "ANALYTICS_MAX_REFRESHES", "ANALYTICS_MAX_POLL_MS", "ANALYTICS_SESSION_TIMEOUT_MS", "ANALYTICS_WORKERS", "ANALYTICS_HEALTH_PORT"
      ] : length([for e in azurerm_container_app.analytics.template[0].container[0].env : e.value if e.name == key]) == 1
    ])
    error_message = "IaC must supply every required worker startup setting, exactly once."
  }

  assert {
    condition = (
      one([for e in azurerm_container_app.analytics.template[0].container[0].env : e.value if e.name == "ANALYTICS_GROUP_ID"]) == "matching-worker-v1" &&
      one([for e in azurerm_container_app.analytics.template[0].container[0].env : e.secret_name if e.name == "ANALYTICS_SIGNING_SECRET"]) == "matching-signing-key" &&
      one([for e in azurerm_container_app.api.template[0].container[0].env : e.secret_name if e.name == "EWASTE_MATCHING_SIGNING_SECRET"]) == "matching-signing-key"
    )
    error_message = "Worker must preserve the existing consumer group and both applications must use secret references."
  }

  assert {
    condition = alltrue([
      for e in azurerm_container_app.analytics.template[0].container[0].env :
      one([for legacy in azurerm_container_app.analytics.template[0].container[0].env :
        legacy.value == e.value && legacy.secret_name == e.secret_name
        if legacy.name == replace(e.name, "ANALYTICS_", "MATCHER_")
      ]) if startswith(e.name, "ANALYTICS_") && e.name != "ANALYTICS_FACADE_URL"
    ])
    error_message = "Legacy rollback images must receive identical worker settings and secret references."
  }

  assert {
    # The generated FQDN is unknown at plan time; both URLs come from the same map.
    condition = alltrue([
      for key in ["ANALYTICS_FACADE_URL", "MATCHER_FACADE_URL"] :
      length([for e in azurerm_container_app.analytics.template[0].container[0].env : e.name if e.name == key]) == 1
    ])
    error_message = "Both worker generations must receive the API URL."
  }
}

run "reject_short_analytics_key" {
  command = plan
  variables {
    analytics_signing_secret = "short"
  }
  expect_failures = [var.analytics_signing_secret]
}

run "legacy_signing_key_remains_usable" {
  command = plan
  variables {
    analytics_signing_secret = null
    matcher_signing_secret   = "local-legacy-key-at-least-32-characters"
  }
  assert {
    condition = alltrue([
      for app in [azurerm_container_app.api, azurerm_container_app.analytics] :
      one([for s in app.secret : s.value if s.name == "matching-signing-key"]) == var.matcher_signing_secret
    ])
    error_message = "Existing tfvars must keep API and worker credentials aligned."
  }
}

run "canonical_key_takes_precedence" {
  command = plan
  variables {
    matcher_signing_secret = "local-legacy-key-at-least-32-characters"
  }
  assert {
    condition     = local.analytics_signing_secret == var.analytics_signing_secret
    error_message = "Explicit analytics settings must take precedence over aliases."
  }
}

run "reject_missing_workload_key" {
  command = plan
  variables {
    analytics_signing_secret = null
  }
  expect_failures = [azurerm_container_app.api]
}

run "reject_short_legacy_key" {
  command = plan
  variables {
    analytics_signing_secret = null
    matcher_signing_secret   = "short"
  }
  expect_failures = [var.matcher_signing_secret]
}

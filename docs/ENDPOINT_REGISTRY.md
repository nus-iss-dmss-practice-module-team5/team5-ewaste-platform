# Canonical Endpoint Registry

**Document Reference:** `docs/ENDPOINT_REGISTRY.md`
**Task:** `S4-TR-T-L-01: Verify runbooks, endpoints and operational evidence`
**Parent Story:** EW-404 / EWCSB-11 (Sprint 4 Production Readiness & Delivery)
**Finding Addressed:** Finding 9 ("Runbook addresses out of date; old dev addresses removed")
**Primary Active Environment:** **Production (`rg-ewaste-prod`)**
**Deployment Region:** `eastasia` (Consolidated per Azure Policy `Allowed resource deployment regions`)
**Network Architecture:** Single Virtual Network (`vnet-ewaste-prod`, `10.0.0.0/16`) partitioned into **4 dedicated subnets** (zero public IP on data/backend).
**Perimeter Access Rule:** **ONLY the Web Frontend UI (`aca-ewaste-prod-ui`) exposes a public endpoint.** The Backend API Gateway (`aca-ewaste-prod-api`), Analytics Matcher Worker (`aca-ewaste-prod-analytics`), MySQL, and Redis are strictly internal.
**Last Verified:** October 2026

---

## 1. Executive Summary & Policy Compliance

Following the Azure subscription migration to subscription `f79417cc-cf5f-4407-809a-1d1bf544571d`, Azure Policy restricts resource deployments strictly to the following 5 regions:

- `eastasia` (Primary Platform Region - Selected for lowest latency and cost tier)
- `koreacentral`
- `indonesiacentral`
- `indiasouthcentral`
- `uaenorth`

**Operational Environment Consolidation:** All active platform workloads, continuous integration verification, and runbook procedures are consolidated exclusively onto the **Production environment (`rg-ewaste-prod`)**. The legacy development resource group (`rg-ewaste-dev`) and its associated ACA container environment in `malaysiawest` (`*.salmoncoast-1b1c8372.malaysiawest...` and `*.kindflower-300f4866.malaysiawest...`) were **permanently destroyed and decommissioned on 9 October 2026**.

**Perimeter Ingress Security Rule:**

- **ONLY the Web Frontend UI (`aca-ewaste-prod-ui`) exposes a public internet endpoint.**
- The **Backend API Gateway (`aca-ewaste-prod-api`)** is configured with **internal ingress only** (`external_enabled = false` in Terraform). It has zero public IP and is accessible exclusively within the Virtual Network and via the Frontend UI reverse proxy.
- The **Analytics Matcher Worker (`aca-ewaste-prod-analytics`)** has **internal ingress only** (`external_enabled = false`).
- All data stores (MySQL, Redis, Storage) are private with zero public IP.

This document serves as the **single source of truth (SSOT)** for all network endpoints, service ports, ingress protocols, health check probes, and credentials routing.

---

## 2. Dynamic Endpoint Discovery CLI

To prevent documentation drift and hardcoded subdomain obsolescence, runbooks and automated scripts **must** query active Azure Container Apps endpoints dynamically via the Azure CLI:

```bash
# Production environment configuration (Default)
export TARGET_ENV="prod"
export RG_NAME="rg-ewaste-prod"

# Discover Production Web UI FQDN (The ONLY public entrypoint)
export UI_FQDN=$(az containerapp show \
  --name "aca-ewaste-prod-ui" \
  --resource-group "${RG_NAME}" \
  --query "properties.configuration.ingress.fqdn" -o tsv)
echo "Public UI Endpoint: https://${UI_FQDN}"

# Discover Production Backend API Internal FQDN (Accessible within VNet only)
export API_INTERNAL_FQDN=$(az containerapp show \
  --name "aca-ewaste-prod-api" \
  --resource-group "${RG_NAME}" \
  --query "properties.configuration.ingress.fqdn" -o tsv)
echo "Internal API FQDN (VNet-only): https://${API_INTERNAL_FQDN}"

# Discover Production Analytics Matcher Worker Internal FQDN (Accessible within VNet only)
export WORKER_INTERNAL_FQDN=$(az containerapp show \
  --name "aca-ewaste-prod-analytics" \
  --resource-group "${RG_NAME}" \
  --query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null || echo "internal")
echo "Internal Worker FQDN (VNet-only): https://${WORKER_INTERNAL_FQDN}"
```

---

## 3. Active Environments Endpoint Catalog

### 3.1. Production Environment (`rg-ewaste-prod`) — Primary Active Release Baseline

| Component               | Resource Name               | Ingress Exposure                              | Port / Protocol  | Active Endpoint / URL                                       | Health Probe Path                  | Access Mechanism                                   |
| :---------------------- | :-------------------------- | :-------------------------------------------- | :--------------- | :---------------------------------------------------------- | :--------------------------------- | :------------------------------------------------- |
| **Web Frontend UI**     | `aca-ewaste-prod-ui`        | **PUBLIC EXTERNAL (Only Public Endpoint)**    | 80, 443 (HTTPS)  | `https://aca-ewaste-prod-ui.eastasia.azurecontainerapps.io` | `GET /`                            | Anonymous / Web Browser (BFF proxy to API)         |
| **Backend API Gateway** | `aca-ewaste-prod-api`       | **INTERNAL ONLY (Zero Public IP)**            | 8080 (HTTPS)     | Internal Cluster DNS (`snet-aca`)                           | `GET /healthz`<br>`GET /readyz`    | Internal VNet only / UI BFF proxy                  |
| **API Documentation**   | `aca-ewaste-prod-api`       | **INTERNAL ONLY**                             | 8080 (HTTPS)     | Internal Cluster DNS / Runner VM                            | `GET /docs`<br>`GET /openapi.yaml` | Internal Swagger                                   |
| **Analytics Matcher**   | `aca-ewaste-prod-analytics` | **INTERNAL ONLY (Zero Public IP)**            | 8000 (HTTP)      | Internal Cluster DNS (`snet-aca`)                           | `GET /readyz`<br>`GET /metrics`    | Internal Ingress / UAMI                            |
| **MySQL Database**      | `mysql-ewaste-prod`         | **100% PRIVATE VNet DELEGATION**              | 3306 (MySQL TLS) | `mysql-ewaste-prod.mysql.database.azure.com:3306`           | TCP Ping via Runner                | User/Password via ACA Encrypted Secrets            |
| **Redis Cache**         | `redis-ewaste-prod`         | **PRIVATE ENDPOINT (snet-private-endpoints)** | 6380 (TLS)       | `redis-ewaste-prod.redis.cache.windows.net:6380`            | Redis PING                         | Secretless Managed Identity / Auth Key             |
| **Event Hubs / Kafka**  | `evh-ewaste-prod`           | **TLS / Entra RBAC**                          | 9093 (Kafka TLS) | `evh-ewaste-prod.servicebus.windows.net:9093`               | Kafka Metadata                     | Managed Identity (`Azure Event Hubs Data Owner`)   |
| **Blob Storage**        | `stgewasteprod`             | **PRIVATE ENDPOINT (snet-private-endpoints)** | 443 (HTTPS)      | `https://stgewasteprod.blob.core.windows.net`               | Blob Service Stats                 | Managed Identity (`Storage Blob Data Contributor`) |
| **Log Stream**          | `log-ewaste-centralized`    | **Private / Azure RBAC**                      | 443 (HTTPS)      | Shared Workspace ID                                         | KQL Workspace API                  | Azure Log Analytics Reader                         |

---

### 3.2. Shared Infrastructure (`rg-ewaste-shared`)

| Component                    | Resource Name            | Region     | Endpoint / Host                                     | Access & Security Notes                                                                                              |
| :--------------------------- | :----------------------- | :--------- | :-------------------------------------------------- | :------------------------------------------------------------------------------------------------------------------- |
| **Container Registry (ACR)** | `acrewasteplatform`      | `eastasia` | `acrewasteplatform.azurecr.io`                      | Premium SKU, Admin Disabled, Public Access Disabled, Private Endpoint inside `snet-private-endpoints`, Cosign signed |
| **Log Analytics Workspace**  | `log-ewaste-centralized` | `eastasia` | Customer ID: dynamically assigned                   | PerGB2018 SKU, 30 days retention, diagnostic sink for all ACA & PaaS                                                 |
| **Resource Group**           | `rg-ewaste-shared`       | `eastasia` | Subscription `f79417cc-cf5f-4407-809a-1d1bf544571d` | Core shared boundary                                                                                                 |

---

### 3.3. Staging Environment (`rg-ewaste-stg`) — Pre-Production / Reference Baseline

| Component               | Resource Name              | Ingress Exposure | Port / Protocol  | Active Endpoint / URL                                      | Health Probe Path               | Access Mechanism             |
| :---------------------- | :------------------------- | :--------------- | :--------------- | :--------------------------------------------------------- | :------------------------------ | :--------------------------- |
| **Web Frontend UI**     | `aca-ewaste-stg-ui`        | External         | 80, 443 (HTTPS)  | `https://aca-ewaste-stg-ui.eastasia.azurecontainerapps.io` | `GET /`                         | Anonymous / Web Browser      |
| **Backend API Gateway** | `aca-ewaste-stg-api`       | Internal Only    | 8080 (HTTPS)     | Internal Cluster DNS (`snet-aca`)                          | `GET /healthz`<br>`GET /readyz` | Internal VNet / UI BFF proxy |
| **Analytics Matcher**   | `aca-ewaste-stg-analytics` | Internal Only    | 8000 (HTTP)      | Internal Cluster DNS (`snet-aca`)                          | `GET /readyz`<br>`GET /metrics` | Internal Ingress / UAMI      |
| **MySQL Database**      | `mysql-ewaste-stg`         | Private VNet     | 3306 (MySQL TLS) | `mysql-ewaste-stg.mysql.database.azure.com:3306`           | TCP Ping via Runner             | Private Subnet `snet-mysql`  |
| **Redis Cache**         | `redis-ewaste-stg`         | Private Endpoint | 6380 (TLS)       | `redis-ewaste-stg.redis.cache.windows.net:6380`            | Redis PING                      | `snet-private-endpoints`     |
| **Event Hubs / Kafka**  | `evh-ewaste-stg`           | TLS / Entra RBAC | 9093 (Kafka TLS) | `evh-ewaste-stg.servicebus.windows.net:9093`               | Kafka Metadata                  | Managed Identity             |
| **Blob Storage**        | `stgewastestg`             | Private Endpoint | 443 (HTTPS)      | `https://stgewastestg.blob.core.windows.net`               | Blob Service Stats              | `snet-private-endpoints`     |

---

## 4. Network Security & Routing Topology (Production: Exactly 4 Subnets)

```
+-------------------------------------------------------------------------------------------------------+
| Azure Subscription: f79417cc-cf5f-4407-809a-1d1bf544571d (Region: eastasia)                           |
+-------------------------------------------------------------------------------------------------------+
                                  |
                                  v
+-------------------------------------------------------------------------------------------------------+
| Shared Services (rg-ewaste-shared)                                                                    |
|   - Azure Container Registry: acrewasteplatform.azurecr.io (Premium, Cosign signed, Private Link)     |
|   - Log Analytics Workspace: log-ewaste-centralized                                                   |
+-------------------------------------------------------------------------------------------------------+
                                  |
                                  v
+-------------------------------------------------------------------------------------------------------+
| Production Environment (rg-ewaste-prod)                                                               |
| Virtual Network: vnet-ewaste-prod (10.0.0.0/16) - EXACTLY 4 DEDICATED SUBNETS                        |
|                                                                                                       |
| [Subnet 1] snet-aca (10.0.8.0/21) - Delegated to Microsoft.App/environments                           |
|       * aca-ewaste-prod-ui         --> PUBLIC INGRESS (ONLY Public Endpoint on HTTPS:443)             |
|       * aca-ewaste-prod-api        --> INTERNAL INGRESS ONLY (Port 8080, Zero Public IP)              |
|       * aca-ewaste-prod-analytics  --> INTERNAL INGRESS ONLY (Port 8000, Zero Public IP)              |
|                                                                                                       |
| [Subnet 2] snet-mysql (10.0.2.0/24) - Delegated to Microsoft.DBforMySQL/flexibleServers              |
|       * mysql-ewaste-prod.mysql.database.azure.com:3306 (100% Private, Zero Public IP)                |
|                                                                                                       |
| [Subnet 3] snet-private-endpoints (10.0.3.0/24) - Hosts ALL Private Endpoints                         |
|       * pe-redis-prod        --> Azure Cache for Redis (redis-ewaste-prod.redis.cache.windows.net:6380)|
|       * pe-stgewaste-prod    --> Blob Storage (stgewasteprod.blob.core.windows.net)                  |
|       * pe-acr-prod          --> Shared Container Registry (acrewasteplatform.azurecr.io)             |
|                                                                                                       |
| [Subnet 4] snet-runner (10.0.4.0/24) - GitHub Actions Self-Hosted VM Runner                           |
|       * vm-runner-ewaste-prod (Inbound Strictly Blocked: NSG DenyAllInboundInternet; Outbound HTTPS)  |
+-------------------------------------------------------------------------------------------------------+
```

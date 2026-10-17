# Azure Subscription Transfer & Infrastructure Bootstrap Runbook

**Platform:** ESG / Circular Economy E-Waste Platform
**Owner:** Lakshanya Poovannan (DevSecOps & Cloud Platform Lead)
**Classification:** Operational Runbook / Standard Operating Procedure (SOP)
**Primary Region:** `malaysiawest` (consistent with all Dev, Staging, and Shared infrastructure)
**Scope:** Transferring the Azure Subscription across accounts/tenants and bootstrapping fresh foundational cloud identity, Terraform state storage, and GitHub Secrets

---

## 1. Executive Summary & Objective

This runbook documents the exact, repeatable operational procedure for:

1. **Transferring an Azure Subscription** between accounts or Microsoft Entra ID (Azure AD) tenants.
2. **Bootstrapping the Terraform State Storage Backend** (`rg-ewaste-tfstate` / `ewastetfstatesa`) in the project's primary region (`malaysiawest`).
3. **Registering required Azure Resource Providers**.
4. **Provisioning the Deployment Service Principal (`gh-actions-ewaste`)** with necessary RBAC roles (`Contributor`, `User Access Administrator`, `AcrPush`, `Key Vault Administrator`).
5. **Configuring the exact GitHub Repository Secrets** required by the automated CI/CD and IaC pipelines.
6. **Resolving Global DNS Name Collisions** (e.g., Azure Container Registry `acrewasteplatform.azurecr.io`).
7. **Troubleshooting Self-Hosted Runner Job Pickup** (`self-hosted`, `azure-vnet`, `dev`).
8. **Cleanly Deleting and Recreating the Self-Hosted Runner & Managing Orphaned Disks**.

> [!WARNING]
> When moving a subscription across Microsoft Entra ID tenants:
>
> - **All existing RBAC role assignments and Service Principals are revoked immediately.**
> - Follow this procedure step-by-step to re-establish deployment credentials, storage state access, and pipeline triggers without data loss.

---

## 2. Pre-Requisites & Initial Authentication

Open your terminal (PowerShell or Bash) and log in to the destination Azure account:

```bash
# 1. Authenticate to Azure
az login

# 2. List all available subscriptions and verify the target subscription ID
az account list --output table

# 3. Set the active subscription context
az account set --subscription "<YOUR_SUBSCRIPTION_ID>"
```

_(Replace `<YOUR_SUBSCRIPTION_ID>` with your active 36-character Azure Subscription GUID)._

---

## 3. Step 1: Register Core Resource Providers

Resource providers must be registered at the subscription level before services can be provisioned.

> [!NOTE]
> Azure's container namespaces are `Microsoft.App` (Container Apps), `Microsoft.ContainerRegistry` (ACR), `Microsoft.ContainerService` (AKS), and `Microsoft.ContainerInstance` (ACI). (`Microsoft.Container` does not exist and returns `InvalidResourceNamespace`).

Run these commands once per subscription:

```bash
az provider register --namespace "Microsoft.App" --wait
az provider register --namespace "Microsoft.OperationalInsights" --wait
az provider register --namespace "Microsoft.ContainerService" --wait
az provider register --namespace "Microsoft.ContainerInstance" --wait
az provider register --namespace "Microsoft.ContainerRegistry" --wait
az provider register --namespace "Microsoft.DBforMySQL" --wait
az provider register --namespace "Microsoft.EventHub" --wait
az provider register --namespace "Microsoft.Network" --wait
az provider register --namespace "Microsoft.Storage" --wait
```

---

## 4. Step 2: Bootstrap Terraform Remote State Storage

Create the dedicated resource group, storage account, and `tfstate` blob container to hold remote `.tfstate` files in the project's primary region (`malaysiawest`):

```bash
# 1. Create the dedicated Resource Group for Terraform State in malaysiawest
az group create --name "rg-ewaste-tfstate" --location "malaysiawest"

# 2. Create the Storage Account (LRS redundancy) in malaysiawest
az storage account create \
  --name "ewastetfstatesa" \
  --resource-group "rg-ewaste-tfstate" \
  --location "malaysiawest" \
  --sku "Standard_LRS"

# 3. Create the 'tfstate' Blob Container
az storage container create \
  --name "tfstate" \
  --account-name "ewastetfstatesa" \
  --auth-mode login
```

### Retrieve the Storage Account Access Key

Retrieve the primary key to authenticate Terraform backend initialization:

```bash
az storage account keys list \
  --resource-group "rg-ewaste-tfstate" \
  --account-name "ewastetfstatesa" \
  --query "[0].value" -o tsv
```

---

## 5. Step 3: Create GitHub Actions Service Principal & Role Grants

Create the automated deployment Service Principal `gh-actions-ewaste` with `Contributor` rights on the subscription.

### 5.1 Create Service Principal with JSON Auth

```bash
az ad sp create-for-rbac \
  --name "gh-actions-ewaste" \
  --role "Contributor" \
  --scopes "/subscriptions/<YOUR_SUBSCRIPTION_ID>" \
  --json-auth
```

**Save the JSON output securely.** It contains:

```json
{
  "clientId": "<CLIENT_ID_FROM_OUTPUT>",
  "clientSecret": "<CLIENT_SECRET_FROM_OUTPUT>",
  "subscriptionId": "<YOUR_SUBSCRIPTION_ID>",
  "tenantId": "<YOUR_TENANT_ID>",
  "activeDirectoryEndpointUrl": "https://login.microsoftonline.com",
  "resourceManagerEndpointUrl": "https://management.azure.com/",
  "activeDirectoryGraphResourceId": "https://graph.windows.net/",
  "sqlManagementEndpointUrl": "https://management.core.windows.net:8443/",
  "galleryEndpointUrl": "https://gallery.azure.com/",
  "managementEndpointUrl": "https://management.core.windows.net/"
}
```

### 5.2 Grant Specific Elevated RBAC Roles

Run the following commands in **PowerShell** (using `` ` `` line continuations) or in **Bash** (using `\` line continuations):

#### In PowerShell:

```powershell
# 1. Grant permission to create Terraform role assignments & manage IAM
az role assignment create `
  --assignee "<CLIENT_ID_FROM_OUTPUT>" `
  --role "User Access Administrator" `
  --scope "/subscriptions/<YOUR_SUBSCRIPTION_ID>"

# 2. Grant permission to write Key Vault secrets (if Key Vault is utilized)
az role assignment create `
  --assignee "<CLIENT_ID_FROM_OUTPUT>" `
  --role "Key Vault Administrator" `
  --scope "/subscriptions/<YOUR_SUBSCRIPTION_ID>"

# 3. Grant permission to push/pull to and from Azure Container Registry
az role assignment create `
  --assignee "<CLIENT_ID_FROM_OUTPUT>" `
  --role "AcrPush" `
  --scope "/subscriptions/<YOUR_SUBSCRIPTION_ID>/resourceGroups/rg-ewaste-shared"
```

#### In Bash:

```bash
# 1. User Access Administrator
az role assignment create \
  --assignee "<CLIENT_ID_FROM_OUTPUT>" \
  --role "User Access Administrator" \
  --scope "/subscriptions/<YOUR_SUBSCRIPTION_ID>"

# 2. Key Vault Administrator
az role assignment create \
  --assignee "<CLIENT_ID_FROM_OUTPUT>" \
  --role "Key Vault Administrator" \
  --scope "/subscriptions/<YOUR_SUBSCRIPTION_ID>"

# 3. AcrPush on Shared ACR Resource Group
az role assignment create \
  --assignee "<CLIENT_ID_FROM_OUTPUT>" \
  --role "AcrPush" \
  --scope "/subscriptions/<YOUR_SUBSCRIPTION_ID>/resourceGroups/rg-ewaste-shared"
```

---

## 6. Step 4: Configure GitHub Repository Secrets

Navigate to your GitHub Repository:
**Settings** $\rightarrow$ **Secrets and variables** $\rightarrow$ **Actions** $\rightarrow$ **New repository secret**.

Populate the complete secrets inventory:

| Secret Name                | Value Description                                | How to Obtain                                                                                                                        |
| :------------------------- | :----------------------------------------------- | :----------------------------------------------------------------------------------------------------------------------------------- |
| `AZURE_CLIENT_ID`          | Application / Client ID of the SP                | `clientId` from `az ad sp create-for-rbac` output                                                                                    |
| `AZURE_CLIENT_SECRET`      | Client Secret password of the SP                 | `clientSecret` from `az ad sp create-for-rbac` output                                                                                |
| `AZURE_SUBSCRIPTION_ID`    | Target Azure Subscription GUID                   | `<YOUR_SUBSCRIPTION_ID>`                                                                                                             |
| `AZURE_TENANT_ID`          | Microsoft Entra ID Tenant GUID                   | `tenantId` from `az ad sp create-for-rbac` output                                                                                    |
| `AZURE_CREDENTIALS`        | Entire raw JSON authentication block             | Full JSON payload returned by `az ad sp create-for-rbac`                                                                             |
| `TF_STATE_SA_ACCESS_KEY`   | Primary Access Key for State Storage             | Output of `az storage account keys list` (Step 2)                                                                                    |
| `TF_STATE_STORAGE_ACCOUNT` | Name of the storage account                      | `ewastetfstatesa`                                                                                                                    |
| `GH_RUNNER_PAT`            | GitHub Personal Access Token (repo scope)        | GitHub $\rightarrow$ Developer Settings $\rightarrow$ Classic PAT with `repo` scope (Required to register the self-hosted runner VM) |
| `MYSQL_DB_ADMIN_PASSWORD`  | Administrator password for MySQL Flexible Server | Strong random secret (minimum 16 chars)                                                                                              |

---

## 7. Step 5: Handling "Registry name is already in use" (Global Name Collision)

Azure Container Registry (ACR) domain names (`<name>.azurecr.io`) are **globally unique across all of Azure worldwide**.

When applying Terraform in `terraform/shared`, you may encounter:

```
Error: the name "acrewasteplatform" used for the Container Registry needs to be globally unique and isn't available: The registry acrewasteplatform is already in use.
```

### Diagnosis Step:

Run the following command in Azure CLI to determine where `acrewasteplatform` currently resides:

```bash
az acr show --name acrewasteplatform --query "id" -o tsv
```

### Resolution Paths:

#### Scenario A: The registry already exists in your CURRENT subscription

_(This happens if the resource was already deployed previously, but you are initializing a brand new Terraform remote state file `tfstate` that does not yet track it)._

- **Fix:** Import the existing ACR and its parent resource group directly into your Terraform state:

```bash
cd terraform/shared

# 1. Import the Shared Resource Group
terraform import azurerm_resource_group.shared /subscriptions/<YOUR_SUBSCRIPTION_ID>/resourceGroups/rg-ewaste-shared

# 2. Import the Container Registry
terraform import azurerm_container_registry.acr /subscriptions/<YOUR_SUBSCRIPTION_ID>/resourceGroups/rg-ewaste-shared/providers/Microsoft.ContainerRegistry/registries/acrewasteplatform

# 3. Import the Centralized Log Analytics Workspace (if already created)
terraform import azurerm_log_analytics_workspace.logs /subscriptions/<YOUR_SUBSCRIPTION_ID>/resourceGroups/rg-ewaste-shared/providers/Microsoft.OperationalInsights/workspaces/log-ewaste-centralized
```

Then run `terraform plan` and `terraform apply`. Terraform will now manage the existing registry instead of trying to create a duplicate.

---

#### Scenario B: The registry still exists in the OLD subscription / account

_(If moving to a completely new subscription and the old subscription still holds `acrewasteplatform`)._
Azure holds the global DNS record for `acrewasteplatform.azurecr.io`. Two choices:

1. **Option 1 (Clean Deletion from Old Subscription):** Log into the old account/subscription and delete `acrewasteplatform` (or delete `rg-ewaste-shared`). Once released by Azure (usually within 1–2 minutes), rerun `terraform apply` in the new subscription.
2. **Option 2 (Use an Appended Suffix Name):** If the old subscription cannot be modified or deleted, update the ACR name to a new globally unique identifier (e.g., `acrewasteplatform01` or `acrewaste<unique_suffix>`) in `terraform/shared/main.tf` and the corresponding `shared_acr_name` variable in `terraform/environments/environments/*.tfvars`.

---

## 8. Step 6: Troubleshooting & Recreating the Self-Hosted Runner

When running `.github/workflows/database-migration.yml`, the workflow states:

```text
Requested labels: self-hosted, azure-vnet, dev
Waiting for a runner to pick up this job...
```

### Why This Happens:

MySQL Flexible Server in Dev (`mysql-ewaste-dev`) is private within `vnet-ewaste-dev`. Public access is blocked. Therefore, Liquibase cannot run on GitHub's hosted `ubuntu-latest` runners. It requires the VNet-injected Linux VM runner (`vm-runner-ewaste-dev`) that carries the three labels:

- `self-hosted`
- `azure-vnet`
- `dev`

If GitHub Actions is stalled waiting for a runner, use either the clean in-place recreation or full VM rebuild below:

---

### 8.1 Procedure A: Clean In-Place Wipe & Recreate (Recommended — 30 Seconds)

This resets the existing Azure VM runner in-place without deleting cloud infrastructure:

1. **Remove Old Runner from GitHub**:
   - Go to GitHub Repository $\rightarrow$ **Settings** $\rightarrow$ **Actions** $\rightarrow$ **Runners**.
   - If `runner-ewaste-dev` is present, click on it and select **Remove** (or Force Remove).
2. **Execute In-Place Wipe and Fresh Registration**:
   - Open Azure Portal $\rightarrow$ Virtual Machines $\rightarrow$ **`vm-runner-ewaste-dev`**.
   - Under **Operations**, select **Run command** $\rightarrow$ **`RunShellScript`**.
   - Paste the following script and click **Run**:

```bash
#!/bin/bash
exec 2>&1
set -x

REPO="nus-iss-dmss-practice-module-team5/team5-ewaste-platform"
RUNNER_DIR="/home/runner/actions-runner"
RUNNER_VER="2.329.0"

# 1. Stop and uninstall any existing runner service
if [ -f "$RUNNER_DIR/svc.sh" ]; then
  cd "$RUNNER_DIR"
  ./svc.sh stop || true
  ./svc.sh uninstall || true
fi

# 2. Wipe directory and download clean runner v2.329.0
mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"
rm -rf "$RUNNER_DIR"/*
curl -sL -o "actions-runner-linux-x64-${RUNNER_VER}.tar.gz" "https://github.com/actions/runner/releases/download/v${RUNNER_VER}/actions-runner-linux-x64-${RUNNER_VER}.tar.gz"
tar -xzf "actions-runner-linux-x64-${RUNNER_VER}.tar.gz"
chown -R runner:runner /home/runner

# 3. Extract PAT from cloud-init user-data
PAT=$(grep -oP 'Authorization: token \K[^"]+' /var/lib/cloud/instance/user-data.txt 2>/dev/null | head -n 1)
if [ -z "$PAT" ]; then
  echo "ERROR: PAT not found in user-data.txt"
  exit 1
fi

# 4. Request a fresh registration token from GitHub API
REG_TOKEN=$(curl -sX POST -H "Accept: application/vnd.github.v3+json" \
  -H "Authorization: token $PAT" \
  "https://api.github.com/repos/${REPO}/actions/runners/registration-token" | jq -r .token)

if [ -z "$REG_TOKEN" ] || [ "$REG_TOKEN" == "null" ]; then
  echo "ERROR: Failed to retrieve registration token from GitHub API"
  exit 1
fi

# 5. Configure runner with required labels
su - runner -c "$RUNNER_DIR/config.sh --url https://github.com/${REPO} --token $REG_TOKEN --name runner-ewaste-dev --labels self-hosted,azure-vnet,dev --unattended --replace"

# 6. Install and start the systemd service
cd "$RUNNER_DIR"
./svc.sh install runner
./svc.sh start
./svc.sh status
echo "SUCCESS: Runner 2.329.0 registered and active!"
```

---

### 8.2 Procedure B: Full Azure VM Deletion, Terraform Recreation & Orphaned Disk Cleanup

To perform an absolute clean rebuild of the VM from bare metal:

1. **Remove Old Runner from GitHub**:
   - Go to GitHub Repository $\rightarrow$ **Settings** $\rightarrow$ **Actions** $\rightarrow$ **Runners** $\rightarrow$ Click `runner-ewaste-dev` $\rightarrow$ Click **Remove**.
2. **Delete the VM in Azure (Including Its Disks)**:
   ```bash
   # Deletes the VM and automatically deletes its OS disk
   az vm delete --resource-group rg-ewaste-dev --name vm-runner-ewaste-dev --yes
   ```
3. **Trigger Terraform Pipeline**:
   - In GitHub Actions, trigger **Terraform - Multi-Environment Provisioning Pipeline** (`dev`).
   - Terraform detects `azurerm_linux_virtual_machine.runner[0]` is missing.
   - Terraform provisions a fresh VM and executes the updated `scripts/runner-init.sh` (which installs runner `>= 2.329.0`), automatically registering `runner-ewaste-dev` with the required labels.

---

### 8.3 Understanding OS Disk Names and Cleaning Up Orphaned Disks

In Azure, when a VM is created via Terraform without a hardcoded `name` in `os_disk {}`, Azure auto-generates a managed disk name following the pattern:

```text
vm-runner-ewaste-dev_OsDisk_1_<32_random_hex_characters>
```

When a VM is deleted without specifying disk deletion flags, the old OS disk remains in Azure as an **`Unattached`** managed disk, incurring idle storage charges.

#### Automated Check & Cleanup Commands

**In Azure Cloud Shell / Bash:**

```bash
# 1. Identify which disk is actively attached to the running VM
ACTIVE_DISK=$(az vm show --resource-group rg-ewaste-dev --name vm-runner-ewaste-dev --query "storageProfile.osDisk.name" -o tsv)
echo "Active disk in use: $ACTIVE_DISK"

# 2. Automatically find and delete all unattached (orphaned) disks in the resource group
ORPHANED_DISKS=$(az disk list --resource-group rg-ewaste-dev --query "[?managedBy==null].name" -o tsv)

for DISK in $ORPHANED_DISKS; do
  echo "Deleting orphaned unattached disk: $DISK"
  az disk delete --resource-group rg-ewaste-dev --name "$DISK" --yes --no-wait
done
```

**In PowerShell:**

```powershell
# 1. Identify active disk
$ActiveDisk = az vm show --resource-group rg-ewaste-dev --name vm-runner-ewaste-dev --query "storageProfile.osDisk.name" -o tsv
Write-Host "Active disk in use: $ActiveDisk"

# 2. Find and delete unattached disks
$OrphanedDisks = az disk list --resource-group rg-ewaste-dev --query "[?managedBy==null].name" -o tsv
foreach ($disk in $OrphanedDisks) {
    Write-Host "Deleting orphaned unattached disk: $disk"
    az disk delete --resource-group rg-ewaste-dev --name $disk --yes --no-wait
}
```

---

## 9. Step 7: Verification & End-to-End Pipeline Smoke Test

Once the secrets are saved in GitHub, the runner VM is online, and state is reconciled:

1. **Verify GitHub Runner Status**:
   - Go to GitHub Repo $\rightarrow$ **Settings** $\rightarrow$ **Actions** $\rightarrow$ **Runners**.
   - Verify `runner-ewaste-dev` is listed with a green **Idle** badge and tags `self-hosted`, `azure-vnet`, `dev`.
2. **Trigger Database Migration**:
   - Trigger **Database - Liquibase Migration** workflow (`dev`).
   - The runner inside `vnet-ewaste-dev` immediately picks up the job, resolves `mysql-ewaste-dev.ewaste-dev.mysql.database.azure.com:3306`, and executes the changelog migrations without network timeout.
3. **Trigger CD Pipeline**:
   - Trigger **CD - Multi-Environment Deployment & Evidence Pipeline** (`dev`).
   - Confirm ACR image build/pull and successful rolling update of Container Apps.

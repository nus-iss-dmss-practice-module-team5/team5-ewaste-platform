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
  location = "malaysiawest"

  tags = {
    Project   = "Responsible E-Waste Chain-of-Custody"
    ManagedBy = "Terraform"
    Tier      = "Shared"
    Course    = "SWE5006"
  }
}

# Centralized Azure Container Registry.
# Premium is required for Private Link. Public access and admin credentials are disabled.
resource "azurerm_container_registry" "acr" {
  # checkov:skip=CKV_AZURE_164:Docker Content Trust cannot be enabled on new ACR registries after 2026-05-31; release images are signed and verified with Cosign in GitHub Actions instead.
  name                          = "acrewasteplatform"
  resource_group_name           = azurerm_resource_group.shared.name
  location                      = "japaneast"
  sku                           = "Premium"
  admin_enabled                 = false
  anonymous_pull_enabled        = false
  public_network_access_enabled = false
  network_rule_bypass_option    = "AzureServices"

  network_rule_set {
    default_action = "Deny"
  }

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
  description = "Shared ACR resource ID for RBAC bindings and environment private endpoints."
}

output "acr_login_server" {
  value       = azurerm_container_registry.acr.login_server
  description = "Shared ACR login server URL."
}

output "log_analytics_workspace_id" {
  value       = azurerm_log_analytics_workspace.logs.id
  description = "Centralized Log Analytics Workspace resource ID."
}

# ============================================================================
# 1. SHARED CI/CD VNET & SUBNETS
# ============================================================================

resource "azurerm_virtual_network" "shared_vnet" {
  name                = "vnet-shared-hub"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  address_space       = ["10.100.0.0/16"]
  tags                = azurerm_resource_group.shared.tags
}

# Subnet for ACR Private Endpoint
resource "azurerm_subnet" "shared_pe_subnet" {
  name                                      = "snet-shared-pe"
  resource_group_name                       = azurerm_resource_group.shared.name
  virtual_network_name                      = azurerm_virtual_network.shared_vnet.name
  address_prefixes                          = ["10.100.1.0/24"]
  private_endpoint_network_policies         = "Disabled"
}

# Subnet for Self-Hosted GitHub Runner VM
resource "azurerm_subnet" "runner_subnet" {
  name                 = "snet-ci-runner"
  resource_group_name  = azurerm_resource_group.shared.name
  virtual_network_name = azurerm_virtual_network.shared_vnet.name
  address_prefixes     = ["10.100.2.0/24"]
}

# ============================================================================
# 2. ACR PRIVATE DNS ZONE & PRIVATE ENDPOINT
# ============================================================================

resource "azurerm_private_dns_zone" "acr_dns" {
  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.shared.name
  tags                = azurerm_resource_group.shared.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "shared_vnet_link" {
  name                  = "vnetlink-shared-hub"
  private_dns_zone_name = azurerm_private_dns_zone.acr_dns.name
  virtual_network_id    = azurerm_virtual_network.shared_vnet.id
  resource_group_name   = azurerm_resource_group.shared.name
}

resource "azurerm_private_endpoint" "shared_acr_pe" {
  name                = "pe-acr-shared"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  subnet_id           = azurerm_subnet.shared_pe_subnet.id
  tags                = azurerm_resource_group.shared.tags

  private_service_connection {
    name                           = "psc-acr-shared"
    private_connection_resource_id = azurerm_container_registry.acr.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr_dns.id]
  }

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.shared_vnet_link
  ]
}

# ============================================================================
# 3. RUNNER IDENTITY & PERMISSIONS
# ============================================================================

resource "azurerm_user_assigned_identity" "runner_id" {
  name                = "id-github-runner"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  tags                = azurerm_resource_group.shared.tags
}

# Allow runner to push directly to ACR
resource "azurerm_role_assignment" "runner_acr_push" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.runner_id.principal_id
}

# ============================================================================
# 4. NETWORK SECURITY GROUP FOR RUNNER
# ============================================================================

resource "azurerm_network_security_group" "runner_nsg" {
  name                = "nsg-shared-runner"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name

  # Outbound HTTPS for GitHub runner long-polling
  security_rule {
    name                       = "AllowOutboundHTTPS"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }

  # Zero Inbound ports needed
  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "runner_nsg_assoc" {
  subnet_id                 = azurerm_subnet.runner_subnet.id
  network_security_group_id = azurerm_network_security_group.runner_nsg.id
}

resource "azurerm_network_interface" "runner_nic" {
  name                = "nic-shared-runner"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.runner_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

# ============================================================================
# 5. SELF-HOSTED RUNNER VM
# ============================================================================

resource "tls_private_key" "runner_ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_linux_virtual_machine" "runner" {
  name                  = "vm-shared-runner"
  location              = "japaneast"
  resource_group_name   = azurerm_resource_group.shared.name
  size                  = "Standard_B1ms"
  admin_username        = var.vm_admin_username
  network_interface_ids = [azurerm_network_interface.runner_nic.id]

  admin_ssh_key {
    username   = var.vm_admin_username
    public_key = tls_private_key.runner_ssh_key.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.runner_id.id]
  }

  # Auto-configures Docker, Azure CLI, and connects runner to GitHub
  custom_data = base64encode(<<-EOF
    #!/bin/bash
    set -e

    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release jq unzip

    # Install Docker
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io
    systemctl enable docker
    systemctl start docker

    # Install Azure CLI
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash

    # Setup GitHub Runner User
    useradd -m actions-runner
    usermod -aG docker actions-runner
    mkdir -p /home/actions-runner/actions-runner && cd /home/actions-runner/actions-runner

    # Download Runner Agent
    RUNNER_VER="2.317.0"
    curl -o actions-runner.tar.gz -L https://github.com/actions/runner/releases/download/v$RUNNER_VER/actions-runner-linux-x64-$RUNNER_VER.tar.gz
    tar xzf ./actions-runner.tar.gz
    chown -R actions-runner:actions-runner /home/actions-runner

    # Register Runner with Custom Label 'azure-vnet-runner'
    sudo -u actions-runner ./config.sh \
      --url "${var.github_repo_url}" \
      --token "${var.github_runner_token}" \
      --name "azure-vnet-runner" \
      --labels "azure-vnet-runner,self-hosted,linux" \
      --work "_work" \
      --unattended \
      --replace

    # Run as a background service
    ./svc.sh install actions-runner
    ./svc.sh start
  EOF
  )

  depends_on = [
    azurerm_network_interface.runner_nic,
    azurerm_subnet_network_security_group_association.runner_nsg_assoc,
    azurerm_private_endpoint.shared_acr_pe,
    azurerm_role_assignment.runner_acr_push
  ]
}
# Identidades de CI para GitHub Actions vía OIDC (Workload Identity
# Federation) - sin ningun secreto de Azure almacenado en GitHub. Mismo
# patron de dos roles que jalcalaroot-azure-bootstrap: "agent" (CRUD, solo
# en push/schedule a main) y "plan" (solo lectura, en PRs).
#
# A diferencia de jalcalaroot-azure-bootstrap (que reutiliza sus identidades
# compartidas con Contributor sobre TODO el resource group "jalcalaroot"),
# estas son identidades DEDICADAS a este proyecto con permisos acotados
# recurso por recurso - minimo privilegio real, no heredado de un RG
# compartido. El costo es mas granularidad de role assignments; el
# beneficio es que si este pipeline se compromete, el blast radius es este
# POC, no toda tu red compartida.
data "azurerm_storage_account" "tfstate" {
  name                = "sttfstatejalcalaroot"
  resource_group_name = "jalcalaroot"
}

resource "azurerm_user_assigned_identity" "ci_agent" {
  name                = "containerapps-poc-agent"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "ci_plan" {
  name                = "containerapps-poc-plan"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

# Subject claims segun el formato ACTUAL de GitHub para este repo
# (confirmado via `gh api repos/jalcalaroot/azure-container-apps-poc/actions/oidc/customization/sub`,
# incluye el sufijo @<owner_id>/@<repo_id> por default, no es una
# personalizacion nuestra). Un rename de owner o repo rompe esto - mismo
# gotcha documentado en jalcalaroot-azure-bootstrap.
#
# Push a main y schedule (cron) presentan el MISMO subject claim
# (ref:refs/heads/main) - por eso una sola federated credential en "agent"
# alcanza para ambos triggers de terraform-apply.yml.
resource "azurerm_federated_identity_credential" "ci_agent_main" {
  name                      = "github-main"
  user_assigned_identity_id = azurerm_user_assigned_identity.ci_agent.id
  issuer                    = "https://token.actions.githubusercontent.com"
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = "repo:jalcalaroot@22682982/azure-container-apps-poc@1358507163:ref:refs/heads/main"
}

resource "azurerm_federated_identity_credential" "ci_plan_pr" {
  name                      = "github-pull-request"
  user_assigned_identity_id = azurerm_user_assigned_identity.ci_plan.id
  issuer                    = "https://token.actions.githubusercontent.com"
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = "repo:jalcalaroot@22682982/azure-container-apps-poc@1358507163:pull_request"
}

# --------------------------------------------------------------------------
# RBAC - acotado recurso por recurso, no todo el resource group compartido.
# --------------------------------------------------------------------------

# Resource group propio del proyecto: agent administra todo (Contributor),
# plan solo necesita ver para poder planear (Reader).
resource "azurerm_role_assignment" "ci_agent_rg_contributor" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.ci_agent.principal_id
}

resource "azurerm_role_assignment" "ci_plan_rg_reader" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.ci_plan.principal_id
}

# DNS Zone existente (azure.jalcalaroot.com, RG jalcalaroot) - acotado a la
# zone especifica, no a todo el RG jalcalaroot. Necesario para el registro A
# "container" Y para el TXT del DNS-01 challenge de Let's Encrypt (mismo
# recurso, mismo permiso).
resource "azurerm_role_assignment" "ci_agent_dns_zone_contributor" {
  scope                = data.azurerm_dns_zone.this.id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.ci_agent.principal_id
}

resource "azurerm_role_assignment" "ci_plan_dns_zone_reader" {
  scope                = data.azurerm_dns_zone.this.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.ci_plan.principal_id
}

# Subnet especifico (snet-containerapps, VNet vnet-jalcalaroot) - solo el
# agent lo necesita, y solo para el "join" que hace el Container Apps
# Environment al crearse/actualizarse. Plan no toca este recurso (no hay
# ningun data source sobre el subnet en este proyecto).
resource "azurerm_role_assignment" "ci_agent_subnet_network_contributor" {
  scope                = var.network_containerapps_subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.ci_agent.principal_id
}

# Backend remoto (sttfstatejalcalaroot): plan TAMBIEN necesita escritura, no
# solo lectura - el locking nativo del backend azurerm usa un blob lease,
# que requiere permisos de escritura incluso para "terraform plan" (mismo
# gotcha ya documentado en jalcalaroot-azure-bootstrap).
resource "azurerm_role_assignment" "ci_agent_state_write" {
  scope                = data.azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.ci_agent.principal_id
}

resource "azurerm_role_assignment" "ci_plan_state_write" {
  scope                = data.azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.ci_plan.principal_id
}

# "Storage Blob Data Contributor" arriba es un rol de DATA PLANE (leer/
# escribir blobs) - no alcanza para que el propio
# `data.azurerm_storage_account.tfstate` (arriba, este mismo archivo) pueda
# leer el objeto ARM de la cuenta de storage, que es una operacion de
# MANAGEMENT PLANE (Microsoft.Storage/storageAccounts/read). Sin esto, el
# primer plan/apply de cualquier identidad nueva contra este backend falla
# con AuthorizationFailed en ese data source - nos paso en la primera
# corrida real del pipeline.
resource "azurerm_role_assignment" "ci_agent_state_reader" {
  scope                = data.azurerm_storage_account.tfstate.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.ci_agent.principal_id
}

resource "azurerm_role_assignment" "ci_plan_state_reader" {
  scope                = data.azurerm_storage_account.tfstate.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.ci_plan.principal_id
}

# El Container Apps Environment (con logs_destination = "log-analytics")
# necesita leer la SHARED KEY del workspace para conectar los logs -
# "Reader" no alcanza (esa accion, Microsoft.OperationalInsights/workspaces/
# sharedKeys/action, esta excluida de Reader a proposito). "Log Analytics
# Contributor" si la incluye. Solo el agent la necesita (create/update real
# del environment); plan se queda con Reader, que ya cubre su refresh.
resource "azurerm_role_assignment" "ci_agent_log_analytics_contributor" {
  scope                = var.network_log_analytics_workspace_id
  role_definition_name = "Log Analytics Contributor"
  principal_id         = azurerm_user_assigned_identity.ci_agent.principal_id
}

resource "azurerm_role_assignment" "ci_plan_log_analytics_reader" {
  scope                = var.network_log_analytics_workspace_id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.ci_plan.principal_id
}

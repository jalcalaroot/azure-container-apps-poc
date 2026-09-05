# Key Vault DEDICADO a este proyecto - deliberadamente NO reutilizamos el
# Key Vault de azure-virtual-network. Ese Key Vault solo tiene Private
# Endpoint (public_network_access_enabled = false) y Application Gateway v2
# no califica como "trusted service", asi que puede leerlo via el Private
# Endpoint (esta en la misma VNet) - PERO importar el certificado ahi es una
# operacion de DATA PLANE contra la API de la vault, que un `terraform apply`
# corriendo fuera de la VNet (ej. tu laptop) no puede alcanzar sin pasar por
# el jumpbox. Para no forzar ese flujo en una POC, esta vault es propia,
# publica (con RBAC, no acceso abierto), asi que tanto el apply como
# Application Gateway pueden llegar sin depender de estar dentro de la VNet.
#
# Los 5 findings de Checkov suprimidos abajo son consecuencia directa de esa
# decision: purge protection off (para poder destroy/recreate limpio en una
# POC desechable) y sin Private Endpoint / firewall (para que el apply y el
# provider acme puedan llegar al data plane sin pasar por la VNet).
resource "azurerm_key_vault" "this" {
  #checkov:skip=CKV_AZURE_42:purge protection off a proposito - POC desechable, necesita destroy/recreate limpio
  #checkov:skip=CKV_AZURE_110:mismo motivo que arriba
  #checkov:skip=CKV_AZURE_109:sin firewall a proposito - RBAC es el control de acceso, no la red (ver comentario arriba)
  #checkov:skip=CKV_AZURE_189:acceso publico intencional - importar el cert es una operacion de data plane que el apply (fuera de la VNet) necesita alcanzar
  #checkov:skip=CKV2_AZURE_32:sin Private Endpoint a proposito - mismo motivo que el finding anterior
  name                       = var.key_vault_name
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false # POC - permite destroy/recreate limpio

  rbac_authorization_enabled    = true
  public_network_access_enabled = true

  tags = local.tags
}

# Quien corre Terraform necesita poder crear/importar certificados. Usamos
# for_each en vez de un unico role assignment atado a
# data.azurerm_client_config.current.object_id a proposito: ese data source
# resuelve a "quien sea que este corriendo terraform ahora mismo", asi que
# con un solo assignment dinamico, alternar entre aplicar localmente y
# aplicar via CI (ci_identities.tf) causaria un destroy+recreate de este
# role assignment en cada cambio de identidad - y durante esa ventana, la
# identidad que ACABA de dejar de ser "current" pierde acceso admin al
# vault. El for_each mantiene el acceso de ambas identidades sin flapping.
resource "azurerm_role_assignment" "current_user_kv_admin" {
  for_each = toset(distinct(concat(
    [data.azurerm_client_config.current.object_id],
    var.extra_key_vault_admin_object_ids,
  )))

  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = each.value
}

# Application Gateway solo necesita leer el secret que respalda el
# certificado - no permisos de administracion.
resource "azurerm_role_assignment" "appgw_kv_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.appgw_kv_reader.principal_id
}

# containerapps-poc-plan (CI, solo lectura - ver ci_identities.tf) necesita
# poder leer el certificado durante el refresh de "terraform plan", pero no
# tiene por que poder crear/modificar nada acá. "Key Vault Reader" es
# metadata-only (no lee el VALOR de secrets), pero si cubre
# certificates/read - suficiente para lo que plan necesita.
resource "azurerm_role_assignment" "ci_plan_kv_reader" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Reader"
  principal_id         = azurerm_user_assigned_identity.ci_plan.principal_id
}

# Las asignaciones RBAC de Azure tardan en propagar (hasta unos minutos).
# Sin esta espera, el primer apply que importa el certificado o crea el
# Application Gateway puede fallar con 403 aunque el role assignment ya
# exista en el plan de Terraform.
resource "time_sleep" "wait_for_kv_rbac" {
  depends_on = [
    azurerm_role_assignment.current_user_kv_admin,
    azurerm_role_assignment.appgw_kv_secrets_user,
  ]
  create_duration = "90s"
}

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
resource "azurerm_key_vault" "this" {
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

# Quien corre Terraform necesita poder crear/importar certificados.
resource "azurerm_role_assignment" "current_user_kv_admin" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Application Gateway solo necesita leer el secret que respalda el
# certificado - no permisos de administracion.
resource "azurerm_role_assignment" "appgw_kv_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.appgw_kv_reader.principal_id
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

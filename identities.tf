# Identidad usada por el Container App para hacer pull de ACR (evita
# credenciales admin embebidas en el registry o en el container app).
resource "azurerm_user_assigned_identity" "containerapp_acr_pull" {
  name                = "id-containerapp-acr-pull"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

# Identidad usada por Application Gateway para leer el certificado desde
# Key Vault. App Gateway v2 no es un "trusted service" de Key Vault - esta
# identidad necesita el rol "Key Vault Secrets User" explicitamente (ver
# role_assignments.tf), sin importar el firewall de la vault.
resource "azurerm_user_assigned_identity" "appgw_kv_reader" {
  name                = "id-appgw-kv-reader"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

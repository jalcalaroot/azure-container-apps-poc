# Azure Container Registry - Basic SKU alcanza para una POC. Admin user
# deshabilitado a proposito: el Container App hace pull con su managed
# identity (ver identities.tf / role_assignments.tf), no con credenciales
# admin embebidas.
resource "azurerm_container_registry" "this" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.tags
}

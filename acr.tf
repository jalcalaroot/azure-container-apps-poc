# Azure Container Registry - Basic SKU alcanza para una POC. Admin user
# deshabilitado a proposito: el Container App hace pull con su managed
# identity (ver identities.tf / role_assignments.tf), no con credenciales
# admin embebidas.
#
# Los 8 findings de Checkov suprimidos abajo son todos features de nivel
# Premium/enterprise (geo-replicacion, zone redundancy, content trust,
# quarantine/vulnerability scanning, dedicated data endpoints, retention
# policy) - no disponibles en Basic SKU y no justificados para una POC de
# hello-world con una sola imagen.
resource "azurerm_container_registry" "this" {
  #checkov:skip=CKV_AZURE_164:content trust requiere Premium SKU - no justificado para una POC
  #checkov:skip=CKV_AZURE_139:acceso publico intencional - Basic SKU no soporta Private Endpoint de todas formas
  #checkov:skip=CKV_AZURE_165:geo-replicacion requiere Premium SKU - una sola region en esta POC
  #checkov:skip=CKV_AZURE_233:zone redundancy requiere Premium SKU
  #checkov:skip=CKV_AZURE_167:retention policy requiere Premium SKU - una sola imagen (hello-world:latest) en esta POC
  #checkov:skip=CKV_AZURE_166:quarantine/scanning requiere Premium SKU
  #checkov:skip=CKV_AZURE_237:dedicated data endpoints requiere Premium SKU
  #checkov:skip=CKV_AZURE_163:vulnerability scanning requiere Premium SKU
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = local.tags
}
